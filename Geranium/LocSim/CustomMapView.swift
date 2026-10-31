//
//  CustomMapView.swift
//  Geranium
//
//  Created by cclerc on 21.12.23.
//  Updated for Route Drawing, Waypoints, and Moving Marker display.
//

import SwiftUI
import MapKit

class WaypointAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let order: Int

    init(coordinate: CLLocationCoordinate2D, order: Int) {
        self.coordinate = coordinate
        self.order = order
        self.title = "Point \(order)"
        super.init()
    }
}

class MovingVehicleAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let title: String?

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        self.title = "Current Position"
        super.init()
    }
}

struct CustomMapView: UIViewRepresentable {
    @Binding var tappedCoordinate: EquatableCoordinate?
    var isRouteMode: Bool
    var waypoints: [RouteWaypoint]
    var currentSimulatedCoord: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.layer.cornerRadius = 15
        mapView.layer.masksToBounds = true

        let tapRecognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tapRecognizer)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self

        // Only update polyline and waypoint annotations when waypoints change
        if waypoints.count != context.coordinator.lastWaypointCount || mapView.overlays.isEmpty {
            context.coordinator.lastWaypointCount = waypoints.count

            mapView.removeOverlays(mapView.overlays)
            if waypoints.count >= 2 {
                let coords = waypoints.map { $0.coordinate }
                let polyline = MKPolyline(coordinates: coords, count: coords.count)
                mapView.addOverlay(polyline)
            }

            let existingWaypointAnns = mapView.annotations.compactMap { $0 as? WaypointAnnotation }
            mapView.removeAnnotations(existingWaypointAnns)

            if isRouteMode || !waypoints.isEmpty {
                let newAnns = waypoints.map { WaypointAnnotation(coordinate: $0.coordinate, order: $0.order) }
                mapView.addAnnotations(newAnns)
            }
        }

        // Update moving vehicle annotation
        let existingVehicleAnn = mapView.annotations.first { $0 is MovingVehicleAnnotation } as? MovingVehicleAnnotation
        if let simCoord = currentSimulatedCoord {
            if let existing = existingVehicleAnn {
                UIView.animate(withDuration: 0.5) {
                    existing.coordinate = simCoord
                }
            } else {
                let vehicleAnn = MovingVehicleAnnotation(coordinate: simCoord)
                mapView.addAnnotation(vehicleAnn)
            }
        } else if let existing = existingVehicleAnn {
            mapView.removeAnnotation(existing)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: CustomMapView
        var lastWaypointCount: Int = -1

        init(_ parent: CustomMapView) {
            self.parent = parent
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            let mapView = gesture.view as! MKMapView
            let touchPoint = gesture.location(in: mapView)
            let coordinate = mapView.convert(touchPoint, toCoordinateFrom: mapView)
            parent.tappedCoordinate = EquatableCoordinate(coordinate: coordinate)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.systemBlue
                renderer.lineWidth = 4.0
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                return nil
            }

            if let waypoint = annotation as? WaypointAnnotation {
                let identifier = "WaypointMarker"
                var marker = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                if marker == nil {
                    marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    marker?.canShowCallout = true
                } else {
                    marker?.annotation = annotation
                }
                marker?.markerTintColor = UIColor.systemBlue
                marker?.glyphText = "\(waypoint.order)"
                return marker
            }

            if annotation is MovingVehicleAnnotation {
                let identifier = "MovingVehicle"
                var marker = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                if marker == nil {
                    marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    marker?.canShowCallout = true
                } else {
                    marker?.annotation = annotation
                }
                marker?.markerTintColor = UIColor.systemGreen
                marker?.glyphImage = UIImage(systemName: "location.north.fill")
                return marker
            }

            return nil
        }
    }
}

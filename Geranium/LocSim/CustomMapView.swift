//
//  CustomMapView.swift
//  Geranium (CompassPro)
//
//  High-Performance MapKit Component for Route Simulation, Vehicle Tracking & Preview Pin.
//

import SwiftUI
import MapKit

final class WaypointAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let order: Int

    init(coordinate: CLLocationCoordinate2D, order: Int) {
        self.coordinate = coordinate
        self.order = order
        self.title = "Điểm \(order)"
        super.init()
    }
}

final class MovingVehicleAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let title: String?

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        self.title = "Vị trí đang chạy"
        super.init()
    }
}

final class PreviewPinAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let title: String?

    init(coordinate: CLLocationCoordinate2D, title: String? = "Vị trí xem trước") {
        self.coordinate = coordinate
        self.title = title
        super.init()
    }
}

struct CustomMapView: UIViewRepresentable {
    @Binding var tappedCoordinate: EquatableCoordinate?
    @Binding var centerCoordinate: EquatableCoordinate?
    var isRouteMode: Bool
    var waypoints: [RouteWaypoint]
    var pathCoordinates: [CLLocationCoordinate2D]
    var currentSimulatedCoord: CLLocationCoordinate2D?
    var previewCoord: CLLocationCoordinate2D?

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

        // 1. Programmatic Map Center (e.g. from location search or bookmark select)
        if let target = centerCoordinate?.coordinate {
            let changed = context.coordinator.lastCenteredCoord == nil ||
                context.coordinator.lastCenteredCoord!.latitude != target.latitude ||
                context.coordinator.lastCenteredCoord!.longitude != target.longitude

            if changed {
                context.coordinator.lastCenteredCoord = target
                let region = MKCoordinateRegion(center: target, latitudinalMeters: 800, longitudinalMeters: 800)
                mapView.setRegion(region, animated: true)
            }
        }

        // 2. Overlays and Waypoints: update ONLY when path or waypoint composition changes
        let pathCount = pathCoordinates.count
        let wpCount = waypoints.count
        if context.coordinator.lastPathCount != pathCount || context.coordinator.lastWaypointCount != wpCount {
            context.coordinator.lastPathCount = pathCount
            context.coordinator.lastWaypointCount = wpCount

            // Update Polyline
            mapView.removeOverlays(mapView.overlays)
            if pathCount >= 2 {
                let polyline = MKPolyline(coordinates: pathCoordinates, count: pathCount)
                mapView.addOverlay(polyline)
            } else if wpCount >= 2 {
                let coords = waypoints.map { $0.coordinate }
                let polyline = MKPolyline(coordinates: coords, count: coords.count)
                mapView.addOverlay(polyline)
            }

            // Update Waypoint Markers
            let oldWaypointAnns = mapView.annotations.compactMap { $0 as? WaypointAnnotation }
            mapView.removeAnnotations(oldWaypointAnns)

            if isRouteMode || !waypoints.isEmpty {
                let newAnns = waypoints.map { WaypointAnnotation(coordinate: $0.coordinate, order: $0.order) }
                mapView.addAnnotations(newAnns)
            }
        }

        // 3. Moving Vehicle Marker: update ONLY when simulated coordinate actually changes
        let existingVehicleAnn = mapView.annotations.first { $0 is MovingVehicleAnnotation } as? MovingVehicleAnnotation
        if let simCoord = currentSimulatedCoord {
            let changed = context.coordinator.lastVehicleCoord == nil ||
                context.coordinator.lastVehicleCoord!.latitude != simCoord.latitude ||
                context.coordinator.lastVehicleCoord!.longitude != simCoord.longitude

            if changed {
                context.coordinator.lastVehicleCoord = simCoord
                if let existing = existingVehicleAnn {
                    UIView.animate(withDuration: 0.5) {
                        existing.coordinate = simCoord
                    }
                } else {
                    let vehicleAnn = MovingVehicleAnnotation(coordinate: simCoord)
                    mapView.addAnnotation(vehicleAnn)
                }
            }
        } else if let existing = existingVehicleAnn {
            context.coordinator.lastVehicleCoord = nil
            mapView.removeAnnotation(existing)
        }

        // 4. Preview Pin Marker: for moving & confirming before setting fake GPS or route waypoint
        let existingPreviewAnn = mapView.annotations.first { $0 is PreviewPinAnnotation } as? PreviewPinAnnotation
        if let pCoord = previewCoord {
            if let existing = existingPreviewAnn {
                UIView.animate(withDuration: 0.2) {
                    existing.coordinate = pCoord
                }
            } else {
                let ann = PreviewPinAnnotation(coordinate: pCoord)
                mapView.addAnnotation(ann)
            }
        } else if let existing = existingPreviewAnn {
            mapView.removeAnnotation(existing)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: CustomMapView
        var lastWaypointCount: Int = -1
        var lastPathCount: Int = -1
        var lastVehicleCoord: CLLocationCoordinate2D? = nil
        var lastCenteredCoord: CLLocationCoordinate2D? = nil

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
                renderer.lineWidth = 4.5
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

            if annotation is PreviewPinAnnotation {
                let identifier = "PreviewPin"
                var marker = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                if marker == nil {
                    marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    marker?.canShowCallout = true
                } else {
                    marker?.annotation = annotation
                }
                marker?.markerTintColor = UIColor.systemOrange
                marker?.glyphImage = UIImage(systemName: "mappin.and.ellipse")
                return marker
            }

            return nil
        }
    }
}

//
//  LocSimManager.swift
//  Geranium (CompassPro)
//
//  Created by Constantin Clerc on 12.11.2022.
//  Re-architected for ultra-reliable, non-blocking GPS simulation.
//

import Foundation
import CoreLocation

/// High-performance thread-safe manager for Apple's private CLSimulationManager
final class LocSimManager {
    static let simManager = CLSimulationManager()
    private static let serialQueue = DispatchQueue(label: "com.compasspro.locsim.queue", qos: .userInteractive)
    private static var isSimulatingActive = false

    /// Updates timezone asynchronously without blocking the calling thread
    static func post_required_timezone_update() {
        CFNotificationCenterPostNotificationWithOptions(
            CFNotificationCenterGetDarwinNotifyCenter(),
            .init("AutomaticTimeZoneUpdateNeeded" as CFString),
            nil,
            nil,
            0
        )
    }

    /// Starts a single-point location simulation (e.g. from map tap or manual coord)
    static func startLocSim(location: CLLocation) {
        serialQueue.async {
            simManager.stopLocationSimulation()
            simManager.clearSimulatedLocations()
            simManager.appendSimulatedLocation(location)
            simManager.flush()
            simManager.startLocationSimulation()
            isSimulatingActive = true
            post_required_timezone_update()
        }
    }

    /// Updates the simulated position during an ongoing route without tearing down the daemon
    static func updateSimulatedLocation(location: CLLocation) {
        serialQueue.async {
            if !isSimulatingActive {
                simManager.stopLocationSimulation()
                simManager.clearSimulatedLocations()
                simManager.appendSimulatedLocation(location)
                simManager.flush()
                simManager.startLocationSimulation()
                isSimulatingActive = true
            } else {
                simManager.clearSimulatedLocations()
                simManager.appendSimulatedLocation(location)
                simManager.flush()
            }
        }
    }

    /// Stops location simulation and returns device to genuine hardware GPS
    static func stopLocSim() {
        serialQueue.async {
            simManager.stopLocationSimulation()
            simManager.clearSimulatedLocations()
            simManager.flush()
            isSimulatingActive = false
            post_required_timezone_update()
        }
    }
}

struct EquatableCoordinate: Equatable {
    var coordinate: CLLocationCoordinate2D

    static func ==(lhs: EquatableCoordinate, rhs: EquatableCoordinate) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

class LocationModel: NSObject, ObservableObject {
    private let locationManager = CLLocationManager()
    @Published var authorisationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        self.locationManager.delegate = self
    }

    public func requestAuthorisation(always: Bool = false) {
        if always {
            self.locationManager.requestAlwaysAuthorization()
        } else {
            self.locationManager.requestWhenInUseAuthorization()
        }
    }
}

extension LocationModel: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        self.authorisationStatus = status
    }
}

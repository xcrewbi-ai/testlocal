//
//  LocSimManager.swift
//  CompassPro
//
//  Re-architected for ultra-reliable, non-blocking GPS simulation.
//  Dynamic runtime bridge compatible with TrollStore (iOS 14-16) and Sideloaded (iOS 17+)
//

import Foundation
import CoreLocation

@objc private protocol CLSimProtocol: NSObjectProtocol {
    func clearSimulatedLocations()
    func startLocationSimulation()
    func stopLocationSimulation()
    func appendSimulatedLocation(_ loc: AnyObject)
    func flush()
}

/// High-performance thread-safe manager for Apple's private CLSimulationManager
final class LocSimManager {
    private static let simManager: CLSimProtocol? = {
        guard let cls = NSClassFromString("CLSimulationManager") as? NSObject.Type else { return nil }
        return cls.init() as? CLSimProtocol
    }()
    
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
            guard let sim = simManager else { return }
            sim.stopLocationSimulation()
            sim.clearSimulatedLocations()
            sim.appendSimulatedLocation(location)
            sim.flush()
            sim.startLocationSimulation()
            isSimulatingActive = true
            post_required_timezone_update()
        }
    }

    /// Updates the simulated position during an ongoing route without tearing down the daemon
    static func updateSimulatedLocation(location: CLLocation) {
        serialQueue.async {
            guard let sim = simManager else { return }
            if !isSimulatingActive {
                sim.stopLocationSimulation()
                sim.clearSimulatedLocations()
                sim.appendSimulatedLocation(location)
                sim.flush()
                sim.startLocationSimulation()
                isSimulatingActive = true
            } else {
                sim.clearSimulatedLocations()
                sim.appendSimulatedLocation(location)
                sim.flush()
            }
        }
    }

    /// Stops location simulation and returns device to genuine hardware GPS with 3x background retries
    static func stopLocSim() {
        for delay in [0.0, 0.15, 0.35] {
            serialQueue.asyncAfter(deadline: .now() + delay) {
                guard let sim = simManager else { return }
                sim.stopLocationSimulation()
                sim.clearSimulatedLocations()
                sim.flush()
                isSimulatingActive = false
                post_required_timezone_update()
            }
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
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorisationStatus = manager.authorizationStatus
    }
}

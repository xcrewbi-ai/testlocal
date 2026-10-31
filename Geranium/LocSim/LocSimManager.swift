//
//  LocSimManager.swift
//  Geranium
//
//  Created by Constantin Clerc on 12.11.2022.
//

import Foundation
import CoreLocation

class LocSimManager {
    static let simManager = CLSimulationManager()
    private static let simQueue = DispatchQueue(label: "live.cclerc.geranium.locsim.queue", qos: .userInteractive)
    private static var isSimulatingActive: Bool = false
    
    /// Updates timezone asynchronously (never deadlocks or blocks calling thread)
    static func post_required_timezone_update() {
        CFNotificationCenterPostNotificationWithOptions(
            CFNotificationCenterGetDarwinNotifyCenter(),
            .init("AutomaticTimeZoneUpdateNeeded" as CFString),
            nil,
            nil,
            0
        )
    }
    
    /// Starts a location simulation of specified argument "location"
    static func startLocSim(location: CLLocation, updateTimezone: Bool = true) {
        simQueue.async {
            simManager.stopLocationSimulation()
            simManager.clearSimulatedLocations()
            simManager.appendSimulatedLocation(location)
            simManager.flush()
            simManager.startLocationSimulation()
            isSimulatingActive = true
            if updateTimezone {
                post_required_timezone_update()
            }
        }
    }

    /// Fast, smooth location update during route simulation without stop/start churn
    static func updateSimulatedLocation(location: CLLocation) {
        simQueue.async {
            simManager.clearSimulatedLocations()
            simManager.appendSimulatedLocation(location)
            simManager.flush()
            if !isSimulatingActive {
                simManager.startLocationSimulation()
                isSimulatingActive = true
            }
        }
    }
    
    /// Stops location simulation
    static func stopLocSim(updateTimezone: Bool = true) {
        simQueue.async {
            simManager.stopLocationSimulation()
            simManager.clearSimulatedLocations()
            simManager.flush()
            isSimulatingActive = false
            if updateTimezone {
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
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        self.authorisationStatus = status
    }
}

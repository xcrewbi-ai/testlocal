//
//  LocationBridge.swift
//  CompassPro
//
//  Unified bridge between CompassPro UI / RouteSimulationEngine and:
//  1. Apple DVT SimulateLocation over Loopback VPN (for iOS 17+ and iOS 27+)
//  2. TrollStore CLSimulationManager (for iOS 14-16)
//  3. Background Keep-Alive Audio (for route simulation in background)
//

import Foundation
import CoreLocation
import MapKit

@MainActor
final class LocationBridge: ObservableObject {
    static let shared = LocationBridge()

    @Published var isDVTReady = false
    @Published var isSimulating = false
    @Published var currentSimulatedCoordinate: CLLocationCoordinate2D?
    @Published var lastError: String?
    @Published var isBusy = false
    @Published var ddiMountStatus: String = "Sẵn sàng"

    private var engine: Engine { Engine.shared }
    private var keepAlive: KeepAlive { KeepAlive.shared }

    /// Checks if a valid developer pairing file exists
    var hasPairingFile: Bool {
        let path = PairingController.pairingFilePath()
        return FileManager.default.fileExists(atPath: path) && (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0) > 0
    }

    /// Checks if the tunnel / VPN is active
    var isTunnelAvailable: Bool {
        engine.tunnelAvailable || engine.vpnConnected
    }

    /// Ensures DDI is downloaded, mounted, and the DVT location session is open
    func ensureDVTReady(quietly: Bool = false) async throws {
        guard !engine.connection.isSimulatingLocation else {
            isDVTReady = true
            return
        }

        if !DeveloperDiskImage.isDownloaded {
            ddiMountStatus = "Đang tải DDI từ mirror..."
            try await DeveloperDiskImage.downloadMissing { fraction in
                Engine.shared.log("DDI download: \(Int(fraction * 100))%")
            }
        }

        ddiMountStatus = "Đang kết nối & Mount DDI..."
        _ = try await engine.prepareLocationSimulation(
            imagePath: DeveloperDiskImage.imagePath,
            trustcachePath: DeveloperDiskImage.trustcachePath,
            manifestPath: DeveloperDiskImage.manifestPath
        ) { fraction in
            Engine.shared.log("DDI mount: \(Int(fraction * 100))%")
        }

        isDVTReady = true
        ddiMountStatus = "Đã kết nối DVT thành công"
    }

    /// Sends simulated coordinate to the device
    func simulate(coordinate: CLLocationCoordinate2D, altitude: Double = 0.0) {
        currentSimulatedCoordinate = coordinate
        isSimulating = true
        lastError = nil

        // 1. TrollStore / iOS 14-16 fallback
        let clLoc = CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: 4.0,
            verticalAccuracy: 4.0,
            timestamp: Date()
        )
        LocSimManager.updateSimulatedLocation(location: clLoc)

        // 2. DVT Simulation over loopback
        Task {
            do {
                if !engine.connection.isSimulatingLocation {
                    try await ensureDVTReady()
                }
                try await engine.simulateLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                keepAlive.startAudio()
            } catch {
                engine.log("LocationBridge simulate error: \(error.localizedDescription)")
                // Do not override with transient network error if user just tapped
            }
        }
    }

    /// Stops GPS simulation and returns device to genuine location
    func stopSimulation() {
        isSimulating = false
        currentSimulatedCoordinate = nil

        // 1. TrollStore stop (3x background retries)
        LocSimManager.stopLocSim()

        // 2. DVT Stop
        Task {
            do {
                if engine.connection.isSimulatingLocation {
                    try await engine.stopSimulatingLocation()
                }
            } catch {
                engine.log("LocationBridge stop error: \(error.localizedDescription)")
            }
            keepAlive.stopAll()
            isDVTReady = false
        }
    }
}

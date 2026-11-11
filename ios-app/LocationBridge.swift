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
    private let keepAlive = KeepAlive()
    private var resendTimer: Timer?
    private static let resendInterval: TimeInterval = 4.0
    private var isSettingUp = false

    /// Checks if a valid developer pairing file exists
    var hasPairingFile: Bool {
        let path = PairingController.pairingFilePath()
        let attr = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attr?[.size] as? NSNumber)?.int64Value ?? 0
        return FileManager.default.fileExists(atPath: path) && size > 0
    }

    /// Checks if the tunnel / VPN is active
    var isTunnelAvailable: Bool {
        engine.tunnelAvailable || engine.vpnConnected
    }

    /// Ensures DDI is downloaded/prepared, mounted, and the DVT location session is open
    func ensureDVTReady() async throws {
        guard !engine.connection.isSimulatingLocation else {
            isDVTReady = true
            return
        }

        // Avoid multiple concurrent setup calls from route timers
        if isSettingUp {
            while isSettingUp {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if engine.connection.isSimulatingLocation {
                isDVTReady = true
                return
            }
            if let err = lastError {
                throw EngineError.message(err)
            }
            return
        }

        isSettingUp = true
        isBusy = true
        defer {
            isSettingUp = false
            isBusy = false
        }

        // 1. Verify Pairing File
        let pairingPath = PairingController.pairingFilePath()
        let pAttr = try? FileManager.default.attributesOfItem(atPath: pairingPath)
        let pSize = (pAttr?[.size] as? NSNumber)?.int64Value ?? 0
        guard FileManager.default.fileExists(atPath: pairingPath) && pSize > 0 else {
            let msg = "Thiết bị chưa được ghép đôi!\n\nVui lòng mở tab 'Ghép đôi', sau đó vào Cài đặt máy > Nhà phát triển > Kết nối và nhập mã PIN để tạo tệp ghép đôi."
            lastError = msg
            throw EngineError.message(msg)
        }

        // 2. Verify Tunnel / VPN is connected
        engine.refreshNetworkStatus()
        guard engine.vpnConnected else {
            let msg = "Chưa kết nối VPN Loopback!\n\nTrên iOS 17+, Apple yêu cầu chạy kết nối DVT qua tunnel.\nVui lòng vào Cài đặt > VPN và bật kết nối VPN (SideStore VPN hoặc WireGuard 10.7.0.1) trước khi bắt đầu Fake GPS."
            lastError = msg
            throw EngineError.message(msg)
        }

        // 3. Prepare DDI (check bundle first, then disk, then download)
        ddiMountStatus = "Đang chuẩn bị Developer Disk Image..."
        try await DeveloperDiskImage.prepareLocalDDI { fraction in
            DispatchQueue.main.async {
                self.ddiMountStatus = "Chuẩn bị DDI: \(Int(fraction * 100))%"
            }
        }

        // 4. Mount DDI & Start DVT Simulation Session
        ddiMountStatus = "Đang kết nối & Mount DDI..."
        _ = try await engine.prepareLocationSimulation(
            imagePath: DeveloperDiskImage.imagePath,
            trustcachePath: DeveloperDiskImage.trustcachePath,
            manifestPath: DeveloperDiskImage.manifestPath
        ) { fraction in
            DispatchQueue.main.async {
                let step = Int(fraction * 4) * 25
                self.ddiMountStatus = "Đang Mount DDI: \(step)%"
            }
        }

        isDVTReady = true
        ddiMountStatus = "Đã kết nối DVT thành công"
        lastError = nil
        engine.log("LocationBridge: DVT ready and location simulation session opened.")
    }

    /// Sends simulated coordinate to the device
    func simulate(coordinate: CLLocationCoordinate2D, altitude: Double = 0.0, isRouteMode: Bool = false) async throws {
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

        // 2. DVT Simulation over loopback (iOS 17+)
        if !engine.connection.isSimulatingLocation {
            try await ensureDVTReady()
        }

        try await engine.simulateLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        keepAlive.startAudio()

        // iOS drops simulated location if not re-sent periodically (every 4s)
        if !isRouteMode {
            startResending()
        } else {
            stopResending()
        }
    }

    /// Periodic resend timer (4 seconds) for single point simulation on iOS 17+
    func startResending() {
        stopResending()
        resendTimer = Timer.scheduledTimer(withTimeInterval: Self.resendInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let simulated = self.currentSimulatedCoordinate, self.isSimulating else { return }
                guard self.engine.connection.isSimulatingLocation else {
                    self.sessionClosed()
                    return
                }
                try? await self.engine.simulateLocation(latitude: simulated.latitude,
                                                        longitude: simulated.longitude)
            }
        }
    }

    func stopResending() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    private func sessionClosed() {
        stopResending()
        isSimulating = false
        currentSimulatedCoordinate = nil
        isDVTReady = false
        keepAlive.stopAll()
        lastError = "Phiên DVT đã bị ngắt. Vui lòng kiểm tra lại VPN và kích hoạt lại."
    }

    /// Stops GPS simulation and returns device to genuine location
    func stopSimulation() {
        isSimulating = false
        currentSimulatedCoordinate = nil
        stopResending()

        // 1. TrollStore stop (with 3x background retries)
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

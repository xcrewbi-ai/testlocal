//
//  RouteSimulationEngine.swift
//  Geranium (CompassPro)
//
//  Upgraded Route Simulation Engine:
//  - Background execution support (CLLocationManager background updates + silent AVAudioSession loop + UIBackgroundTask)
//  - Global adjustable base speed (km/h) & variance (+- km/h) on the fly
//  - Segment-by-segment custom speed configuration (multi-select / individual)
//  - Corner deceleration down to 40% on sharp turns (0° to 120° / heading change >= 35°)
//  - Estimated Time of Arrival (ETA) duration and arrival clock time
//  - Lateral drift +-2m orthogonal to route
//

import Foundation
import CoreLocation
import Combine
import UIKit
import AVFoundation

struct RouteWaypoint: Identifiable, Equatable {
    let id: UUID
    var coordinate: CLLocationCoordinate2D
    var order: Int

    init(coordinate: CLLocationCoordinate2D, order: Int) {
        self.id = UUID()
        self.coordinate = coordinate
        self.order = order
    }

    static func == (lhs: RouteWaypoint, rhs: RouteWaypoint) -> Bool {
        lhs.id == rhs.id
    }
}

struct RouteSegment: Identifiable, Equatable {
    let id: Int // 0, 1, 2...
    var startIndex: Int // 1, 2, ...
    var endIndex: Int // 2, 3, ...
    var distanceMeters: Double
    var customSpeedKmh: Double? // nil = use globalBaseSpeedKmh
    var customVarianceKmh: Double? // nil = use globalSpeedVarianceKmh
    var turnAngleDegrees: Double // turn angle at start of segment
    var isSharpTurn: Bool // turn angle >= 35° (corner angle 0° to 120°)
}

class RouteSimulationEngine: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = RouteSimulationEngine()

    // MARK: - Published Properties
    @Published var waypoints: [RouteWaypoint] = []
    @Published var segments: [RouteSegment] = []
    @Published var isSimulating: Bool = false
    @Published var isPaused: Bool = false
    @Published var currentSpeedKmh: Double = 30.0
    @Published var globalBaseSpeedKmh: Double = 30.0
    @Published var globalSpeedVarianceKmh: Double = 5.0
    @Published var totalDistanceMeters: Double = 0.0
    @Published var distanceCoveredMeters: Double = 0.0
    @Published var progressPercent: Double = 0.0
    @Published var currentCoordinate: CLLocationCoordinate2D? = nil
    @Published var isLooping: Bool = false

    // ETA properties
    @Published var etaRemainingSeconds: Double = 0.0
    @Published var etaFormattedDuration: String = "--"
    @Published var etaArrivalTimeString: String = "--:--"

    // Current segment tracking
    @Published var currentSegmentIndex: Int = 0

    // MARK: - Internal Simulation State
    private var timer: DispatchSourceTimer?
    private var distanceAlongCurrentSegment: Double = 0.0
    private var currentLateralOffset: Double = 0.0
    private let tickIntervalSeconds: Double = 1.0
    private let earthRadiusMeters = 6378137.0

    // Altitude to apply during route simulation
    var simulationAltitude: Double = 0.0

    // Background Execution Helpers
    private let locationManager = CLLocationManager()
    private var silentAudioPlayer: AVAudioPlayer?
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    private override init() {
        super.init()
        setupLocationManager()
    }

    // MARK: - Background Service Management

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.requestAlwaysAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Keeps iOS background location pipeline active while app is minimized or locked
    }

    private func startBackgroundServices() {
        // 1. Location updates for background persistence
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.startUpdatingLocation()

        // 2. Silent audio loop
        setupSilentAudio()

        // 3. UIBackgroundTask
        startBackgroundTask()
    }

    private func stopBackgroundServices() {
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        stopSilentAudio()
        endBackgroundTask()
    }

    private func startBackgroundTask() {
        endBackgroundTask()
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "CompassProBackgroundRoute") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if bgTaskId != .invalid {
            let taskId = bgTaskId
            bgTaskId = .invalid
            UIApplication.shared.endBackgroundTask(taskId)
        }
    }

    private func setupSilentAudio() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                let audioData = self.createSilentWAVData()
                let player = try AVAudioPlayer(data: audioData)
                player.numberOfLoops = -1
                player.volume = 0.01
                player.prepareToPlay()
                player.play()
                DispatchQueue.main.async {
                    self.silentAudioPlayer = player
                }
            } catch {
                print("Background audio error: \(error)")
            }
        }
    }

    private func stopSilentAudio() {
        silentAudioPlayer?.stop()
        silentAudioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func createSilentWAVData() -> Data {
        let sampleRate: Int32 = 8000
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let durationSeconds = 1
        let numSamples = Int(sampleRate) * durationSeconds
        let dataSize = Int32(numSamples * Int(numChannels) * Int(bitsPerSample / 8))
        let fileSize = 36 + dataSize

        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        var fileSizeLE = fileSize.littleEndian
        data.append(Data(bytes: &fileSizeLE, count: 4))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45, 0x66, 0x6D, 0x74, 0x20]) // "WAVEfmt "
        var subchunk1Size: Int32 = 16
        data.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat: Int16 = 1 // PCM
        data.append(Data(bytes: &audioFormat, count: 2))
        var channels = numChannels.littleEndian
        data.append(Data(bytes: &channels, count: 2))
        var sRate = sampleRate.littleEndian
        data.append(Data(bytes: &sRate, count: 4))
        var byteRate = (sampleRate * Int32(numChannels) * Int32(bitsPerSample / 8)).littleEndian
        data.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = (numChannels * (bitsPerSample / 8)).littleEndian
        data.append(Data(bytes: &blockAlign, count: 2))
        var bps = bitsPerSample.littleEndian
        data.append(Data(bytes: &bps, count: 2))
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        var dSize = dataSize.littleEndian
        data.append(Data(bytes: &dSize, count: 4))
        data.append(Data(count: Int(dataSize)))
        return data
    }

    // MARK: - Waypoint & Segment Management

    func addWaypoint(_ coordinate: CLLocationCoordinate2D) {
        guard !isSimulating else { return }
        let newWaypoint = RouteWaypoint(coordinate: coordinate, order: waypoints.count + 1)
        waypoints.append(newWaypoint)
        recalculateSegments()
        updateETA()
    }

    func removeLastWaypoint() {
        guard !isSimulating, !waypoints.isEmpty else { return }
        waypoints.removeLast()
        recalculateSegments()
        updateETA()
    }

    func clearRoute() {
        stopSimulation()
        waypoints.removeAll()
        segments.removeAll()
        totalDistanceMeters = 0.0
        distanceCoveredMeters = 0.0
        progressPercent = 0.0
        currentCoordinate = nil
        currentSegmentIndex = 0
        updateETA()
    }

    func recalculateSegments() {
        guard waypoints.count >= 2 else {
            segments = []
            totalDistanceMeters = 0.0
            return
        }

        var newSegments: [RouteSegment] = []
        var totalDist: Double = 0.0

        for i in 0..<(waypoints.count - 1) {
            let p1 = waypoints[i].coordinate
            let p2 = waypoints[i + 1].coordinate
            let loc1 = CLLocation(latitude: p1.latitude, longitude: p1.longitude)
            let loc2 = CLLocation(latitude: p2.latitude, longitude: p2.longitude)
            let segDist = loc1.distance(from: loc2)
            totalDist += segDist

            // Calculate turn angle at start of segment (waypoint i)
            var turnAngle: Double = 0.0
            var isSharp: Bool = false
            if i > 0 {
                let p0 = waypoints[i - 1].coordinate
                let bPrev = calculateBearing(from: p0, to: p1)
                let bCur = calculateBearing(from: p1, to: p2)
                var diff = abs(bCur - bPrev).truncatingRemainder(dividingBy: 360.0)
                if diff > 180.0 { diff = 360.0 - diff }
                turnAngle = diff
                // Sharp turn: heading change between 35° and 180° (interior angle 0° to 145°)
                isSharp = turnAngle >= 35.0
            }

            // Preserve previous customization if present
            var existingSpeed: Double? = nil
            var existingVariance: Double? = nil
            if i < segments.count {
                existingSpeed = segments[i].customSpeedKmh
                existingVariance = segments[i].customVarianceKmh
            }

            newSegments.append(RouteSegment(
                id: i,
                startIndex: i + 1,
                endIndex: i + 2,
                distanceMeters: segDist,
                customSpeedKmh: existingSpeed,
                customVarianceKmh: existingVariance,
                turnAngleDegrees: turnAngle,
                isSharpTurn: isSharp
            ))
        }

        self.segments = newSegments
        self.totalDistanceMeters = totalDist
    }

    // MARK: - Segment Speed Customization

    func setSpeedForSegments(indices: Set<Int>, speedKmh: Double?, varianceKmh: Double?) {
        for idx in indices {
            if idx >= 0 && idx < segments.count {
                segments[idx].customSpeedKmh = speedKmh
                segments[idx].customVarianceKmh = varianceKmh
            }
        }
        updateETA()
    }

    func resetAllSegmentSpeeds() {
        for i in 0..<segments.count {
            segments[i].customSpeedKmh = nil
            segments[i].customVarianceKmh = nil
        }
        updateETA()
    }

    // MARK: - Simulation Control

    func startSimulation() {
        guard waypoints.count >= 2 else { return }
        if isPaused {
            resumeSimulation()
            return
        }

        currentSegmentIndex = 0
        distanceAlongCurrentSegment = 0.0
        distanceCoveredMeters = 0.0
        currentSpeedKmh = segments.first?.customSpeedKmh ?? globalBaseSpeedKmh
        currentLateralOffset = 0.0
        isSimulating = true
        isPaused = false

        startBackgroundServices()
        startTimer()
        updateETA()
    }

    func pauseSimulation() {
        guard isSimulating, !isPaused else { return }
        isPaused = true
        stopTimer()
        stopBackgroundServices()
    }

    func resumeSimulation() {
        guard isSimulating, isPaused else { return }
        isPaused = false
        startBackgroundServices()
        startTimer()
    }

    func stopSimulation() {
        stopTimer()
        stopBackgroundServices()
        isSimulating = false
        isPaused = false
        distanceCoveredMeters = 0.0
        progressPercent = 0.0
        currentSegmentIndex = 0
        distanceAlongCurrentSegment = 0.0
        currentCoordinate = nil
        updateETA()
        LocSimManager.stopLocSim()
    }

    func finishRouteAtDestination() {
        stopTimer()
        stopBackgroundServices()
        isSimulating = false
        isPaused = false
        currentSpeedKmh = 0.0
        progressPercent = 1.0
        distanceCoveredMeters = totalDistanceMeters
        if let destination = waypoints.last?.coordinate {
            currentCoordinate = destination
        }
        updateETA()
    }

    // MARK: - Timer & Movement Logic

    private func startTimer() {
        stopTimer()
        let queue = DispatchQueue(label: "live.cclerc.geranium.routesim", qos: .userInteractive)
        let newTimer = DispatchSource.makeTimerSource(queue: queue)
        newTimer.schedule(deadline: .now(), repeating: tickIntervalSeconds)
        newTimer.setEventHandler { [weak self] in
            self?.simulationTick()
        }
        newTimer.resume()
        self.timer = newTimer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Corner Braking & Speed Calculation

    private func computeTargetSpeedForCurrentPosition() -> (targetSpeed: Double, variance: Double) {
        guard currentSegmentIndex < segments.count else {
            return (globalBaseSpeedKmh, globalSpeedVarianceKmh)
        }

        let curSeg = segments[currentSegmentIndex]
        let base = curSeg.customSpeedKmh ?? globalBaseSpeedKmh
        let variance = curSeg.customVarianceKmh ?? globalSpeedVarianceKmh

        var cornerFactor = 1.0

        // 1. Approach to corner at end of this segment:
        if currentSegmentIndex + 1 < segments.count {
            let nextSeg = segments[currentSegmentIndex + 1]
            if nextSeg.isSharpTurn {
                let distToEnd = max(0.0, curSeg.distanceMeters - distanceAlongCurrentSegment)
                let brakingZone: Double = 30.0 // meters before corner
                if distToEnd <= brakingZone {
                    // Decelerate down to 40% (0.4) at the corner waypoint
                    let progressInBraking = distToEnd / brakingZone
                    let factor = 0.4 + (0.6 * progressInBraking)
                    cornerFactor = min(cornerFactor, factor)
                }
            }
        }

        // 2. Exit from corner at start of this segment:
        if curSeg.isSharpTurn {
            let distFromStart = distanceAlongCurrentSegment
            let accelerationZone: Double = 20.0 // meters after corner
            if distFromStart <= accelerationZone {
                // Accelerate from 40% (0.4) back to 100% (1.0)
                let progressInAccel = distFromStart / accelerationZone
                let factor = 0.4 + (0.6 * progressInAccel)
                cornerFactor = min(cornerFactor, factor)
            }
        }

        let targetSpeed = max(5.0, base * cornerFactor)
        return (targetSpeed, variance * cornerFactor)
    }

    private func simulationTick() {
        guard isSimulating, !isPaused, waypoints.count >= 2 else { return }

        // Compute current target speed (accounting for segment custom speed & corner deceleration)
        let (targetSpeed, variance) = computeTargetSpeedForCurrentPosition()

        // Fluctuate within [targetSpeed - variance ... targetSpeed + variance]
        let minSpeed = max(5.0, targetSpeed - variance)
        let maxSpeed = targetSpeed + variance
        let randomTarget = Double.random(in: minSpeed...maxSpeed)

        // Smooth transition towards randomTarget (max 2.5 km/h per second)
        let delta = randomTarget - currentSpeedKmh
        let maxStep = 2.5
        let clampedDelta = max(-maxStep, min(maxStep, delta))
        let newSpeed = max(3.0, currentSpeedKmh + clampedDelta)

        // Convert to m/s
        let speedMps = newSpeed / 3.6
        let stepDistance = speedMps * tickIntervalSeconds

        // Advance along route
        advanceDistance(stepDistance, speedKmh: newSpeed, speedMps: speedMps)
    }

    private func advanceDistance(_ stepDistance: Double, speedKmh: Double, speedMps: Double) {
        if currentSegmentIndex >= waypoints.count - 1 {
            // Reached the end of route
            if isLooping {
                currentSegmentIndex = 0
                distanceAlongCurrentSegment = 0.0
                distanceCoveredMeters = 0.0
            } else {
                if let lastCoord = waypoints.last?.coordinate {
                    sendSimulatedLocation(coordinate: lastCoord, course: 0.0, speed: 0.0)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.finishRouteAtDestination()
                }
                return
            }
        }

        let startCoord = waypoints[currentSegmentIndex].coordinate
        let endCoord = waypoints[currentSegmentIndex + 1].coordinate

        let locA = CLLocation(latitude: startCoord.latitude, longitude: startCoord.longitude)
        let locB = CLLocation(latitude: endCoord.latitude, longitude: endCoord.longitude)
        let segmentDistance = locA.distance(from: locB)

        distanceAlongCurrentSegment += stepDistance
        distanceCoveredMeters += stepDistance

        // Check if we passed the current segment
        if distanceAlongCurrentSegment >= segmentDistance {
            let leftover = distanceAlongCurrentSegment - segmentDistance
            currentSegmentIndex += 1
            distanceAlongCurrentSegment = 0.0

            if currentSegmentIndex >= waypoints.count - 1 {
                if isLooping {
                    currentSegmentIndex = 0
                    distanceAlongCurrentSegment = leftover
                    distanceCoveredMeters = leftover
                } else {
                    sendSimulatedLocation(
                        coordinate: endCoord,
                        course: calculateBearing(from: startCoord, to: endCoord),
                        speed: 0.0
                    )
                    DispatchQueue.main.async { [weak self] in
                        self?.finishRouteAtDestination()
                    }
                    return
                }
            }
        }

        // Compute intermediate position on current segment with +-2m lateral drift
        let currentStart = waypoints[currentSegmentIndex].coordinate
        let currentEnd = waypoints[currentSegmentIndex + 1].coordinate
        let currentSegmentLen = CLLocation(latitude: currentStart.latitude, longitude: currentStart.longitude)
            .distance(from: CLLocation(latitude: currentEnd.latitude, longitude: currentEnd.longitude))

        let fraction = currentSegmentLen > 0 ? (distanceAlongCurrentSegment / currentSegmentLen) : 0.0

        // Smooth lateral drift between -2.0m and +2.0m
        let targetDrift = Double.random(in: -2.0...2.0)
        currentLateralOffset = (currentLateralOffset * 0.85) + (targetDrift * 0.15)
        currentLateralOffset = max(-2.0, min(2.0, currentLateralOffset))

        let computedCoord = computeInterpolatedCoordinate(
            from: currentStart,
            to: currentEnd,
            fraction: fraction,
            lateralOffsetMeters: currentLateralOffset
        )

        let bearing = calculateBearing(from: currentStart, to: currentEnd)

        // Send to LocSimManager
        sendSimulatedLocation(coordinate: computedCoord, course: bearing, speed: speedMps)

        // Update main thread state & ETA
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentSpeedKmh = speedKmh
            self.currentCoordinate = computedCoord
            if self.totalDistanceMeters > 0 {
                self.progressPercent = min(1.0, self.distanceCoveredMeters / self.totalDistanceMeters)
            }
            self.updateETA()
        }
    }

    private func sendSimulatedLocation(coordinate: CLLocationCoordinate2D, course: Double, speed: Double) {
        let location = CLLocation(
            coordinate: coordinate,
            altitude: simulationAltitude,
            horizontalAccuracy: 4.0,
            verticalAccuracy: 4.0,
            course: course,
            speed: speed,
            timestamp: Date()
        )
        LocSimManager.startLocSim(location: location)
    }

    // MARK: - ETA Calculation

    func updateETA() {
        guard totalDistanceMeters > 0 else {
            etaFormattedDuration = "--"
            etaArrivalTimeString = "--:--"
            etaRemainingSeconds = 0.0
            return
        }

        let remainingDistance = max(0.0, totalDistanceMeters - distanceCoveredMeters)
        if remainingDistance <= 0 {
            etaFormattedDuration = "0s"
            etaArrivalTimeString = "Đã đến"
            etaRemainingSeconds = 0.0
            return
        }

        var remainingSeconds: Double = 0.0
        if currentSegmentIndex < segments.count {
            // Remainder of current segment
            let curSeg = segments[currentSegmentIndex]
            let curSpeed = (curSeg.customSpeedKmh ?? globalBaseSpeedKmh) / 3.6
            let curRemainDist = max(0.0, curSeg.distanceMeters - distanceAlongCurrentSegment)
            remainingSeconds += (curRemainDist / max(1.0, curSpeed))

            // Subsequent segments
            if currentSegmentIndex + 1 < segments.count {
                for i in (currentSegmentIndex + 1)..<segments.count {
                    let seg = segments[i]
                    let spd = (seg.customSpeedKmh ?? globalBaseSpeedKmh) / 3.6
                    remainingSeconds += (seg.distanceMeters / max(1.0, spd))
                }
            }
        } else {
            let spd = max(5.0, currentSpeedKmh) / 3.6
            remainingSeconds = remainingDistance / spd
        }

        self.etaRemainingSeconds = remainingSeconds

        let totalSecs = Int(remainingSeconds)
        let hours = totalSecs / 3600
        let minutes = (totalSecs % 3600) / 60
        let seconds = totalSecs % 60

        if hours > 0 {
            etaFormattedDuration = "\(hours)h \(minutes)p"
        } else if minutes > 0 {
            etaFormattedDuration = "\(minutes)p \(seconds)s"
        } else {
            etaFormattedDuration = "\(seconds)s"
        }

        let arrivalDate = Date().addingTimeInterval(remainingSeconds)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        etaArrivalTimeString = formatter.string(from: arrivalDate)
    }

    // MARK: - Mathematical Helpers

    private func computeInterpolatedCoordinate(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fraction: Double,
        lateralOffsetMeters: Double
    ) -> CLLocationCoordinate2D {
        let lat1 = from.latitude * .pi / 180.0
        let lon1 = from.longitude * .pi / 180.0
        let lat2 = to.latitude * .pi / 180.0
        let lon2 = to.longitude * .pi / 180.0

        let avgLat = (lat1 + lat2) / 2.0
        let dx = (lon2 - lon1) * cos(avgLat) * earthRadiusMeters
        let dy = (lat2 - lat1) * earthRadiusMeters
        let len = sqrt(dx * dx + dy * dy)

        if len == 0 { return from }

        let tx = dx / len
        let ty = dy / len
        let nx = -ty
        let ny = tx

        let px = fraction * dx + lateralOffsetMeters * nx
        let py = fraction * dy + lateralOffsetMeters * ny

        let resultLat = (lat1 + (py / earthRadiusMeters)) * 180.0 / .pi
        let resultLon = (lon1 + (px / (earthRadiusMeters * cos(avgLat)))) * 180.0 / .pi

        return CLLocationCoordinate2D(latitude: resultLat, longitude: resultLon)
    }

    private func calculateBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180.0
        let lon1 = from.longitude * .pi / 180.0
        let lat2 = to.latitude * .pi / 180.0
        let lon2 = to.longitude * .pi / 180.0

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)
        let degrees = radians * 180.0 / .pi
        return (degrees + 360.0).truncatingRemainder(dividingBy: 360.0)
    }
}

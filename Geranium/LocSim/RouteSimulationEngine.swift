//
//  RouteSimulationEngine.swift
//  Geranium (CompassPro)
//
//  Clean Foreground Route Simulation Engine:
//  - 100% stable, zero background conflicts
//  - Live adjustable speed (km/h) & variance on the fly
//  - Segment-by-segment custom speed configuration
//  - Corner deceleration down to 40% on sharp turns (0° to 120°)
//  - Estimated Time of Arrival (ETA) duration and arrival clock
//  - Lateral drift +-2m orthogonal to route
//  - Pins simulated GPS location at destination upon completion
//

import Foundation
import CoreLocation
import Combine

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
    var isSharpTurn: Bool // corner 0° to 120° (heading turn >= 35°)
}

class RouteSimulationEngine: ObservableObject {
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

    private init() {}

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
            var isSharp: Bool = false
            if i > 0 {
                let p0 = waypoints[i - 1].coordinate
                let bPrev = calculateBearing(from: p0, to: p1)
                let bCur = calculateBearing(from: p1, to: p2)
                var diff = abs(bCur - bPrev).truncatingRemainder(dividingBy: 360.0)
                if diff > 180.0 { diff = 360.0 - diff }
                // Sharp turn: heading turn >= 35° (interior angle 0° to 145°)
                isSharp = diff >= 35.0
            }

            // Preserve existing customization if present
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

        startTimer()
        updateETA()
    }

    func pauseSimulation() {
        guard isSimulating, !isPaused else { return }
        isPaused = true
        stopTimer()
    }

    func resumeSimulation() {
        guard isSimulating, isPaused else { return }
        isPaused = false
        startTimer()
    }

    func stopSimulation() {
        stopTimer()
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
        isSimulating = false
        isPaused = false
        currentSpeedKmh = 0.0
        progressPercent = 1.0
        distanceCoveredMeters = totalDistanceMeters
        if let destination = waypoints.last?.coordinate {
            currentCoordinate = destination
        }
        updateETA()
        // Notice: LocSimManager.stopLocSim() is NOT called! Keeps location pinned at destination.
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

    private func simulationTick() {
        guard isSimulating, !isPaused, waypoints.count >= 2 else { return }

        // 1. Target speed & variance based on current segment
        let curSeg = (currentSegmentIndex < segments.count) ? segments[currentSegmentIndex] : nil
        let baseSpeed = curSeg?.customSpeedKmh ?? globalBaseSpeedKmh
        let variance = curSeg?.customVarianceKmh ?? globalSpeedVarianceKmh

        // 2. Corner deceleration down to 40% on sharp corners (0° to 120°)
        var cornerFactor = 1.0
        if currentSegmentIndex + 1 < segments.count && segments[currentSegmentIndex + 1].isSharpTurn {
            let distToEnd = max(0.0, (curSeg?.distanceMeters ?? 50.0) - distanceAlongCurrentSegment)
            if distToEnd <= 25.0 {
                // Decelerate down to 40% (0.4) approaching corner
                cornerFactor = 0.4 + (0.6 * (distToEnd / 25.0))
            }
        } else if curSeg?.isSharpTurn == true && distanceAlongCurrentSegment <= 15.0 {
            // Accelerate from 40% (0.4) back to 100% exiting corner
            cornerFactor = 0.4 + (0.6 * (distanceAlongCurrentSegment / 15.0))
        }

        let targetSpeed = max(5.0, baseSpeed * cornerFactor)
        let targetVariance = variance * cornerFactor

        // 3. Smooth momentum acceleration (same proven formula as original 2e14e80)
        let deltaV = Double.random(in: -1.2...1.2)
        var newSpeed = currentSpeedKmh + deltaV
        let minV = max(3.0, targetSpeed - targetVariance)
        let maxV = targetSpeed + targetVariance
        newSpeed = max(minV, min(maxV, newSpeed))

        // Convert speed to m/s
        let speedMps = newSpeed / 3.6
        let stepDistance = speedMps * tickIntervalSeconds

        // 4. Advance along route
        advanceDistance(stepDistance, speedKmh: newSpeed, speedMps: speedMps)
    }

    private func advanceDistance(_ stepDistance: Double, speedKmh: Double, speedMps: Double) {
        guard currentSegmentIndex < waypoints.count - 1 else {
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

        // 5. Compute intermediate position on current segment with +-2m lateral drift
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

        // 6. Send to LocSimManager
        sendSimulatedLocation(coordinate: computedCoord, course: bearing, speed: speedMps)

        // 7. Update main thread state & ETA
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

        let spd = max(5.0, currentSpeedKmh) / 3.6
        let remainingSeconds = remainingDistance / spd
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

//
//  RouteSimulationEngine.swift
//  Geranium
//
//  Created for Route Simulation with realistic speed and lateral drift.
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

class RouteSimulationEngine: ObservableObject {
    static let shared = RouteSimulationEngine()

    // MARK: - Published Properties
    @Published var waypoints: [RouteWaypoint] = []
    @Published var isSimulating: Bool = false
    @Published var isPaused: Bool = false
    @Published var currentSpeedKmh: Double = 30.0
    @Published var totalDistanceMeters: Double = 0.0
    @Published var distanceCoveredMeters: Double = 0.0
    @Published var progressPercent: Double = 0.0
    @Published var currentCoordinate: CLLocationCoordinate2D? = nil
    @Published var isLooping: Bool = false

    // MARK: - Internal Simulation State
    private var timer: DispatchSourceTimer?
    private var currentSegmentIndex: Int = 0
    private var distanceAlongCurrentSegment: Double = 0.0
    private var currentLateralOffset: Double = 0.0
    private let tickIntervalSeconds: Double = 1.0
    private let earthRadiusMeters = 6378137.0

    // Altitude to apply during route simulation
    var simulationAltitude: Double = 0.0

    private init() {}

    // MARK: - Waypoint Management

    func addWaypoint(_ coordinate: CLLocationCoordinate2D) {
        guard !isSimulating else { return }
        let newWaypoint = RouteWaypoint(coordinate: coordinate, order: waypoints.count + 1)
        waypoints.append(newWaypoint)
        recalculateTotalDistance()
    }

    func removeLastWaypoint() {
        guard !isSimulating, !waypoints.isEmpty else { return }
        waypoints.removeLast()
        recalculateTotalDistance()
    }

    func clearRoute() {
        stopSimulation()
        waypoints.removeAll()
        totalDistanceMeters = 0.0
        distanceCoveredMeters = 0.0
        progressPercent = 0.0
        currentCoordinate = nil
    }

    private func recalculateTotalDistance() {
        guard waypoints.count >= 2 else {
            totalDistanceMeters = 0.0
            return
        }
        var total: Double = 0.0
        for i in 0..<(waypoints.count - 1) {
            let locA = CLLocation(latitude: waypoints[i].coordinate.latitude, longitude: waypoints[i].coordinate.longitude)
            let locB = CLLocation(latitude: waypoints[i + 1].coordinate.latitude, longitude: waypoints[i + 1].coordinate.longitude)
            total += locA.distance(from: locB)
        }
        totalDistanceMeters = total
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
        currentSpeedKmh = 30.0
        currentLateralOffset = 0.0
        isSimulating = true
        isPaused = false

        // Start timer
        startTimer()
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
        LocSimManager.stopLocSim()
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

        // 1. Calculate random speed in range 30 +- 5 km/h (25 km/h to 35 km/h) with smooth acceleration
        let deltaV = Double.random(in: -1.2...1.2)
        var newSpeed = currentSpeedKmh + deltaV
        newSpeed = max(25.0, min(35.0, newSpeed))

        // Convert speed to m/s
        let speedMps = newSpeed / 3.6
        let stepDistance = speedMps * tickIntervalSeconds

        // 2. Advance along route
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
                DispatchQueue.main.async { [weak self] in
                    self?.stopSimulation()
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
                    // Send final waypoint location then stop
                    sendSimulatedLocation(
                        coordinate: endCoord,
                        course: calculateBearing(from: startCoord, to: endCoord),
                        speed: 0.0
                    )
                    DispatchQueue.main.async { [weak self] in
                        self?.stopSimulation()
                    }
                    return
                }
            }
        }

        // 3. Compute intermediate position on current segment with +-2m lateral drift
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

        // 4. Send to LocSimManager
        sendSimulatedLocation(coordinate: computedCoord, course: bearing, speed: speedMps)

        // 5. Update main thread state
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentSpeedKmh = speedKmh
            self.currentCoordinate = computedCoord
            if self.totalDistanceMeters > 0 {
                self.progressPercent = min(1.0, self.distanceCoveredMeters / self.totalDistanceMeters)
            }
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

    // MARK: - Mathematical Helpers

    /// Computes interpolated coordinate along segment with orthogonal lateral offset
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

        // Flat projection relative to 'from' in meters
        let avgLat = (lat1 + lat2) / 2.0
        let dx = (lon2 - lon1) * cos(avgLat) * earthRadiusMeters
        let dy = (lat2 - lat1) * earthRadiusMeters
        let len = sqrt(dx * dx + dy * dy)

        if len == 0 { return from }

        // Unit tangent vector T = (tx, ty)
        let tx = dx / len
        let ty = dy / len

        // Unit normal vector N = (-ty, tx) (perpendicular to path)
        let nx = -ty
        let ny = tx

        // Point along path in meters
        let px = fraction * dx + lateralOffsetMeters * nx
        let py = fraction * dy + lateralOffsetMeters * ny

        // Convert back to lat/lon
        let resultLat = (lat1 + (py / earthRadiusMeters)) * 180.0 / .pi
        let resultLon = (lon1 + (px / (earthRadiusMeters * cos(avgLat)))) * 180.0 / .pi

        return CLLocationCoordinate2D(latitude: resultLat, longitude: resultLon)
    }

    /// Computes bearing (heading in degrees 0...360) between two coordinates
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

//
//  RouteSimulationEngine.swift
//  Geranium (CompassPro)
//
//  High-Performance GPS Route Simulation Engine with Auto Road Routing & Zero Freezing.
//

import Foundation
import CoreLocation
import MapKit

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
    var roadCoordinates: [CLLocationCoordinate2D]

    static func == (lhs: RouteSegment, rhs: RouteSegment) -> Bool {
        lhs.id == rhs.id &&
        lhs.distanceMeters == rhs.distanceMeters &&
        lhs.customSpeedKmh == rhs.customSpeedKmh &&
        lhs.customVarianceKmh == rhs.customVarianceKmh &&
        lhs.roadCoordinates.count == rhs.roadCoordinates.count
    }
}

final class RouteSimulationEngine: ObservableObject {
    static let shared = RouteSimulationEngine()

    // MARK: - Published Properties
    @Published var waypoints: [RouteWaypoint] = []
    @Published var segments: [RouteSegment] = []
    @Published var allPathCoordinates: [CLLocationCoordinate2D] = []
    @Published var isAutoRouting: Bool = true // Smart road routing via Apple Maps
    @Published var isCalculatingRoute: Bool = false

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
    private let timerQueue = DispatchQueue(label: "com.compasspro.routesim.timer", qos: .userInteractive)
    private var currentSubSegmentIndex: Int = 0
    private var distanceAlongSubSegment: Double = 0.0
    private var currentLateralOffset: Double = 0.0
    private let tickIntervalSeconds: Double = 1.0
    private let earthRadiusMeters = 6378137.0

    // Static cached date formatter to avoid allocating inside tight loops
    private static let arrivalDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // Altitude to apply during route simulation
    var simulationAltitude: Double = 0.0

    private init() {}

    // MARK: - Waypoint & Segment Management

    func addWaypoint(_ coordinate: CLLocationCoordinate2D) {
        let newWaypoint = RouteWaypoint(coordinate: coordinate, order: waypoints.count + 1)
        waypoints.append(newWaypoint)

        if !isSimulating && currentCoordinate == nil {
            currentCoordinate = coordinate
        }

        if waypoints.count >= 2 {
            let segIdx = waypoints.count - 2
            let prevCoord = waypoints[segIdx].coordinate

            if isAutoRouting {
                // 1. Immediately create straight segment for instant responsiveness
                let straightSeg = buildStraightSegment(id: segIdx, from: prevCoord, to: coordinate)
                segments.append(straightSeg)
                recalculateTotals()
                updateETA()

                // 2. Fetch driving road directions asynchronously
                isCalculatingRoute = true
                calculateDirections(from: prevCoord, to: coordinate) { [weak self] roadCoords, roadDist in
                    DispatchQueue.main.async {
                        guard let self = self, segIdx < self.segments.count else { return }
                        self.segments[segIdx].roadCoordinates = roadCoords
                        self.segments[segIdx].distanceMeters = roadDist
                        self.recalculateTotals()
                        self.updateETA()
                        self.isCalculatingRoute = false
                    }
                }
            } else {
                let straightSeg = buildStraightSegment(id: segIdx, from: prevCoord, to: coordinate)
                segments.append(straightSeg)
                recalculateTotals()
                updateETA()
            }
        } else {
            recalculateTotals()
            updateETA()
        }
    }

    func removeLastWaypoint() {
        guard !waypoints.isEmpty else { return }
        if isSimulating {
            guard waypoints.count > currentSegmentIndex + 2 else { return }
        }
        waypoints.removeLast()
        if !segments.isEmpty {
            segments.removeLast()
        }
        recalculateTotals()
        updateETA()
    }

    /// Clears the route lines and waypoints while ALWAYS preserving fake GPS at the current/final location.
    func clearRoute() {
        stopTimer()
        isSimulating = false
        isPaused = false
        currentSpeedKmh = 0.0

        // Retain the last known position so device never reverts to real GPS
        let finalCoord = currentCoordinate ?? waypoints.last?.coordinate ?? waypoints.first?.coordinate
        if let final = finalCoord {
            currentCoordinate = final
            sendSimulatedLocation(coordinate: final, course: 0.0, speed: 0.0)
        }

        waypoints.removeAll()
        segments.removeAll()
        allPathCoordinates.removeAll()
        totalDistanceMeters = 0.0
        distanceCoveredMeters = 0.0
        progressPercent = 0.0
        currentSegmentIndex = 0
        currentSubSegmentIndex = 0
        distanceAlongSubSegment = 0.0

        updateETA()
    }

    /// Completes the route early: identical to clearRoute().
    func completeRouteAndClear() {
        clearRoute()
    }

    private func buildStraightSegment(id: Int, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> RouteSegment {
        let loc1 = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let loc2 = CLLocation(latitude: to.latitude, longitude: to.longitude)
        let dist = loc1.distance(from: loc2)

        return RouteSegment(
            id: id,
            startIndex: id + 1,
            endIndex: id + 2,
            distanceMeters: dist,
            customSpeedKmh: nil,
            customVarianceKmh: nil,
            isSharpTurn: false,
            roadCoordinates: [from, to]
        )
    }

    private func calculateDirections(
        from startCoord: CLLocationCoordinate2D,
        to endCoord: CLLocationCoordinate2D,
        completion: @escaping ([CLLocationCoordinate2D], Double) -> Void
    ) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: startCoord))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: endCoord))
        request.transportType = .automobile

        let directions = MKDirections(request: request)
        directions.calculate { response, error in
            if let route = response?.routes.first, route.polyline.pointCount >= 2 {
                var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: route.polyline.pointCount)
                route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: route.polyline.pointCount))
                completion(coords, route.distance)
            } else {
                // Fallback to straight line
                let loc1 = CLLocation(latitude: startCoord.latitude, longitude: startCoord.longitude)
                let loc2 = CLLocation(latitude: endCoord.latitude, longitude: endCoord.longitude)
                completion([startCoord, endCoord], loc1.distance(from: loc2))
            }
        }
    }

    func recalculateTotals() {
        var allCoords: [CLLocationCoordinate2D] = []
        var totalDist: Double = 0.0

        for i in 0..<segments.count {
            let seg = segments[i]
            totalDist += seg.distanceMeters

            // Check sharp turn at start of segment
            if i > 0 && segments[i - 1].roadCoordinates.count >= 2 && seg.roadCoordinates.count >= 2 {
                let prevCoords = segments[i - 1].roadCoordinates
                let p0 = prevCoords[prevCoords.count - 2]
                let p1 = prevCoords[prevCoords.count - 1]
                let p2 = seg.roadCoordinates[1]

                let b1 = calculateBearing(from: p0, to: p1)
                let b2 = calculateBearing(from: p1, to: p2)
                var diff = abs(b2 - b1)
                if diff > 180.0 { diff = 360.0 - diff }
                segments[i].isSharpTurn = diff >= 35.0
            }

            if allCoords.isEmpty {
                allCoords.append(contentsOf: seg.roadCoordinates)
            } else if seg.roadCoordinates.count > 1 {
                // Skip duplicate joining point
                allCoords.append(contentsOf: seg.roadCoordinates.dropFirst())
            }
        }

        self.allPathCoordinates = allCoords
        self.totalDistanceMeters = totalDist
    }

    func setSpeedForSegments(indices: Set<Int>, speedKmh: Double?, varianceKmh: Double?) {
        for idx in indices {
            if idx >= 0 && idx < segments.count {
                segments[idx].customSpeedKmh = speedKmh
                segments[idx].customVarianceKmh = varianceKmh
            }
        }
        updateETA()
    }

    /// Clean, non-blocking global speed setter
    func setGlobalSpeedKmh(_ speed: Double) {
        let clamped = max(10.0, min(120.0, speed))
        globalBaseSpeedKmh = clamped
        if !isSimulating {
            currentSpeedKmh = clamped
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

        if currentSegmentIndex >= segments.count || (totalDistanceMeters > 0 && distanceCoveredMeters >= totalDistanceMeters) {
            currentSegmentIndex = 0
            currentSubSegmentIndex = 0
            distanceAlongSubSegment = 0.0
            distanceCoveredMeters = 0.0
        }

        let curSeg = (currentSegmentIndex < segments.count) ? segments[currentSegmentIndex] : nil
        currentSpeedKmh = curSeg?.customSpeedKmh ?? globalBaseSpeedKmh
        currentLateralOffset = 0.0
        isSimulating = true
        isPaused = false

        if currentCoordinate == nil || (currentSegmentIndex == 0 && distanceAlongSubSegment == 0.0) {
            if let firstCoord = waypoints.first?.coordinate {
                currentCoordinate = firstCoord
                sendSimulatedLocation(coordinate: firstCoord, course: 0.0, speed: 0.0)
            }
        }

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

    /// Called ONLY when user taps the master "Dừng GPS" button in the top navigation bar.
    func stopSimulation() {
        stopTimer()
        isSimulating = false
        isPaused = false
        distanceCoveredMeters = 0.0
        progressPercent = 0.0
        currentSegmentIndex = 0
        currentSubSegmentIndex = 0
        distanceAlongSubSegment = 0.0
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
            sendSimulatedLocation(coordinate: destination, course: 0.0, speed: 0.0)
        }
        updateETA()
        // Crucial: LocSimManager.stopLocSim() is NOT called! Keeps location permanently pinned.
    }

    // MARK: - Timer & Movement Logic

    private func startTimer() {
        stopTimer()
        let newTimer = DispatchSource.makeTimerSource(queue: timerQueue)
        newTimer.schedule(deadline: .now() + tickIntervalSeconds, repeating: tickIntervalSeconds)
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
        guard isSimulating, !isPaused, !segments.isEmpty else { return }
        guard currentSegmentIndex < segments.count else {
            DispatchQueue.main.async { [weak self] in
                self?.finishRouteAtDestination()
            }
            return
        }

        let curSeg = segments[currentSegmentIndex]
        let baseSpeed = curSeg.customSpeedKmh ?? globalBaseSpeedKmh
        let variance = curSeg.customVarianceKmh ?? globalSpeedVarianceKmh

        // Corner deceleration down to 40% when approaching sharp turns
        var cornerFactor = 1.0
        let roadCoords = curSeg.roadCoordinates
        if currentSubSegmentIndex + 1 < roadCoords.count - 1 {
            let p0 = roadCoords[currentSubSegmentIndex]
            let p1 = roadCoords[currentSubSegmentIndex + 1]
            let p2 = roadCoords[currentSubSegmentIndex + 2]
            let b1 = calculateBearing(from: p0, to: p1)
            let b2 = calculateBearing(from: p1, to: p2)
            var diff = abs(b2 - b1)
            if diff > 180.0 { diff = 360.0 - diff }
            if diff >= 35.0 {
                let subDist = CLLocation(latitude: p0.latitude, longitude: p0.longitude)
                    .distance(from: CLLocation(latitude: p1.latitude, longitude: p1.longitude))
                let distToTurn = max(0.0, subDist - distanceAlongSubSegment)
                if distToTurn <= 20.0 {
                    cornerFactor = 0.4 + (0.6 * (distToTurn / 20.0))
                }
            }
        }

        let targetSpeed = max(5.0, baseSpeed * cornerFactor)
        let targetVariance = variance * cornerFactor

        let deltaV = Double.random(in: -1.2...1.2)
        var newSpeed = currentSpeedKmh + deltaV
        let minV = max(3.0, targetSpeed - targetVariance)
        let maxV = targetSpeed + targetVariance
        newSpeed = max(minV, min(maxV, newSpeed))

        let speedMps = newSpeed / 3.6
        let stepDist = speedMps * tickIntervalSeconds

        advanceAlongRoad(stepDist, speedKmh: newSpeed, speedMps: speedMps)
    }

    private func advanceAlongRoad(_ stepDistance: Double, speedKmh: Double, speedMps: Double) {
        var remainingStep = stepDistance
        distanceCoveredMeters += stepDistance

        while remainingStep > 0 {
            guard currentSegmentIndex < segments.count else { break }
            let curSeg = segments[currentSegmentIndex]
            let roadCoords = curSeg.roadCoordinates
            guard roadCoords.count >= 2 else { break }

            if currentSubSegmentIndex >= roadCoords.count - 1 {
                // Move to next segment
                currentSegmentIndex += 1
                currentSubSegmentIndex = 0
                distanceAlongSubSegment = 0.0

                if currentSegmentIndex >= segments.count {
                    if isLooping {
                        currentSegmentIndex = 0
                        currentSubSegmentIndex = 0
                        distanceAlongSubSegment = 0.0
                        distanceCoveredMeters = 0.0
                        break
                    } else {
                        let lastCoord = waypoints.last?.coordinate ?? roadCoords.last!
                        sendSimulatedLocation(coordinate: lastCoord, course: 0.0, speed: 0.0)
                        DispatchQueue.main.async { [weak self] in
                            self?.finishRouteAtDestination()
                        }
                        return
                    }
                }
                continue
            }

            let pA = roadCoords[currentSubSegmentIndex]
            let pB = roadCoords[currentSubSegmentIndex + 1]
            let subDist = CLLocation(latitude: pA.latitude, longitude: pA.longitude)
                .distance(from: CLLocation(latitude: pB.latitude, longitude: pB.longitude))

            let needed = max(0.1, subDist - distanceAlongSubSegment)
            if remainingStep >= needed {
                remainingStep -= needed
                distanceAlongSubSegment = 0.0
                currentSubSegmentIndex += 1
            } else {
                distanceAlongSubSegment += remainingStep
                remainingStep = 0.0
            }
        }

        guard currentSegmentIndex < segments.count else { return }
        let curSeg = segments[currentSegmentIndex]
        let roadCoords = curSeg.roadCoordinates
        let subIdx = min(currentSubSegmentIndex, max(0, roadCoords.count - 2))
        guard roadCoords.count >= 2 else { return }

        let pA = roadCoords[subIdx]
        let pB = roadCoords[subIdx + 1]
        let subDist = max(0.1, CLLocation(latitude: pA.latitude, longitude: pA.longitude)
            .distance(from: CLLocation(latitude: pB.latitude, longitude: pB.longitude)))

        let fraction = min(1.0, max(0.0, distanceAlongSubSegment / subDist))

        // Drift +-2m
        let targetDrift = Double.random(in: -2.0...2.0)
        currentLateralOffset = (currentLateralOffset * 0.85) + (targetDrift * 0.15)
        currentLateralOffset = max(-2.0, min(2.0, currentLateralOffset))

        let computedCoord = computeInterpolatedCoordinate(
            from: pA,
            to: pB,
            fraction: fraction,
            lateralOffsetMeters: currentLateralOffset
        )
        let bearing = calculateBearing(from: pA, to: pB)

        sendSimulatedLocation(coordinate: computedCoord, course: bearing, speed: speedMps)

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
        LocSimManager.updateSimulatedLocation(location: location)
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

        let effectiveSpeedKmh = (isSimulating && currentSpeedKmh >= 5.0) ? currentSpeedKmh : globalBaseSpeedKmh
        let spdMps = max(2.5, effectiveSpeedKmh / 3.6)
        let remainingSeconds = remainingDistance / spdMps
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
        etaArrivalTimeString = Self.arrivalDateFormatter.string(from: arrivalDate)
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
        let radiansBearing = atan2(y, x)
        let degrees = radiansBearing * 180.0 / .pi
        return (degrees + 360.0).truncatingRemainder(dividingBy: 360.0)
    }
}

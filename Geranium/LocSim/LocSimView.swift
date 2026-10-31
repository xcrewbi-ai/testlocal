//
//  LocSimView.swift
//  Geranium (CompassPro)
//
//  Re-architected Fake GPS with Route Simulation:
//  - Clean, responsive UI with zero deadlock risk
//  - Live adjustable speed on the fly (km/h)
//  - Estimated Time of Arrival (ETA) duration & arrival clock
//  - Segment-by-segment speed & variance customizer
//  - Corner deceleration down to 40% on sharp turns
//  - Master Stop GPS on top bar (removed accidental Stop in panel)
//

import SwiftUI
import CoreLocation
import AlertKit

enum LocSimMode: String, CaseIterable, Identifiable {
    case single = "Điểm đơn"
    case route = "Lộ trình"

    var id: String { self.rawValue }
}

struct LocSimView: View {
    @StateObject private var appSettings = AppSettings()
    @StateObject private var routeEngine = RouteSimulationEngine.shared

    @State private var mode: LocSimMode = .single
    @State private var lat: Double = 0.0
    @State private var long: Double = 0.0
    @State private var altitude: String = "0.0"
    @State private var tappedCoordinate: EquatableCoordinate? = nil
    @State private var bookmarkSheetTggle: Bool = false
    @State private var showSegmentSheet: Bool = false

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                contentBody
            }
        } else {
            NavigationView {
                contentBody
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        ZStack(alignment: .bottom) {
            // Interactive MapKit View
            CustomMapView(
                tappedCoordinate: $tappedCoordinate,
                isRouteMode: mode == .route,
                waypoints: routeEngine.waypoints,
                currentSimulatedCoord: routeEngine.currentCoordinate
            )
            .ignoresSafeArea(edges: .bottom)
            .onAppear {
                LocationModel().requestAuthorisation()
            }

            // Route Floating Control Bar (shown only when in route mode)
            if mode == .route {
                RouteControlPanel()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
        }
        .onChange(of: tappedCoordinate) { newValue in
            guard let coord = newValue?.coordinate else { return }
            if mode == .single {
                let altitudeValue = Double(altitude) ?? 0.0
                startSingleSimulation(at: coord, altitude: altitudeValue)
            } else {
                routeEngine.addWaypoint(coord)
            }
        }
        .onChange(of: altitude) { newAlt in
            routeEngine.simulationAltitude = Double(newAlt) ?? 0.0
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Picker("Chế độ", selection: $mode) {
                    ForEach(LocSimMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                // Manual coordinate entry
                Button(action: showManualCoordAlert) {
                    Image(systemName: "mappin")
                        .font(.system(size: 16, weight: .semibold))
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                // Altitude setting
                Button(action: showAltitudeAlert) {
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                // Master Stop Simulation button
                Button(action: {
                    stopAllSimulation()
                    AlertKitAPI.present(
                        title: "Đã dừng GPS!",
                        icon: .done,
                        style: .iOS17AppleMusic,
                        haptic: .success
                    )
                }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.red)
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                // Bookmarks
                Button(action: {
                    self.bookmarkSheetTggle.toggle()
                }) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 16, weight: .semibold))
                }
                .sheet(isPresented: $bookmarkSheetTggle) {
                    BookMarkSlider(lat: $lat, long: $long)
                }
            }
        }
    }

    // MARK: - Route Floating Control Panel
    @ViewBuilder
    private func RouteControlPanel() -> some View {
        VStack(spacing: 8) {
            // Stats Row
            statsHeaderRow

            // ETA Row (shown if 2+ waypoints)
            if routeEngine.waypoints.count >= 2 {
                etaRow
            }

            // Live Speed Slider Row
            liveSpeedSliderRow

            // Progress bar
            if routeEngine.isSimulating {
                ProgressView(value: routeEngine.progressPercent)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                    .padding(.horizontal, 12)
            }

            // Buttons row
            actionButtonsRow
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
        )
    }

    private var statsHeaderRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tốc độ")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                HStack(spacing: 2) {
                    Text(String(format: "%.1f", routeEngine.currentSpeedKmh))
                        .font(.headline.bold())
                    Text("km/h")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Divider().frame(height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Quãng đường")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(formatDistance(routeEngine.totalDistanceMeters))
                    .font(.subheadline.bold())
            }

            Divider().frame(height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Điểm")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(routeEngine.waypoints.count)")
                    .font(.subheadline.bold())
            }

            Spacer()

            // Loop toggle
            Button(action: {
                routeEngine.isLooping.toggle()
            }) {
                Image(systemName: routeEngine.isLooping ? "repeat.1" : "repeat")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(7)
                    .background(routeEngine.isLooping ? Color.blue.opacity(0.2) : Color.gray.opacity(0.15))
                    .foregroundColor(routeEngine.isLooping ? .blue : .primary)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var etaRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.fill")
                .font(.caption)
                .foregroundColor(.blue)

            Text("Ước tính:")
                .font(.caption)
                .foregroundColor(.secondary)

            Text(routeEngine.etaFormattedDuration)
                .font(.caption.bold())
                .foregroundColor(.primary)

            Text("• Đến: \(routeEngine.etaArrivalTimeString)")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            let remainDist = max(0.0, routeEngine.totalDistanceMeters - routeEngine.distanceCoveredMeters)
            Text("Còn \(formatDistance(remainDist))")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.1))
                .foregroundColor(.blue)
                .cornerRadius(4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(.systemGray6).opacity(0.6))
        .cornerRadius(6)
        .padding(.horizontal, 12)
    }

    private var liveSpeedSliderRow: some View {
        HStack(spacing: 8) {
            Text("Tốc độ:")
                .font(.caption2)
                .foregroundColor(.secondary)

            Button(action: {
                routeEngine.globalBaseSpeedKmh = max(10, routeEngine.globalBaseSpeedKmh - 5)
                routeEngine.updateETA()
            }) {
                Text("-5")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(.systemGray5))
                    .cornerRadius(4)
            }

            Slider(value: $routeEngine.globalBaseSpeedKmh, in: 10...120, step: 1)
                .onChange(of: routeEngine.globalBaseSpeedKmh) { _ in
                    routeEngine.updateETA()
                }

            Button(action: {
                routeEngine.globalBaseSpeedKmh = min(120, routeEngine.globalBaseSpeedKmh + 5)
                routeEngine.updateETA()
            }) {
                Text("+5")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(.systemGray5))
                    .cornerRadius(4)
            }

            Text("\(Int(routeEngine.globalBaseSpeedKmh)) km/h")
                .font(.caption.bold())
                .frame(width: 55, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }

    private var actionButtonsRow: some View {
        HStack(spacing: 10) {
            // Clear button
            Button(action: {
                routeEngine.clearRoute()
            }) {
                Label("Xóa", systemImage: "trash")
                    .font(.caption)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(Color(.systemGray5))
                    .foregroundColor(.red)
                    .cornerRadius(8)
            }
            .disabled(routeEngine.waypoints.isEmpty)

            // Undo last point
            Button(action: {
                routeEngine.removeLastWaypoint()
            }) {
                Label("Lùi", systemImage: "arrow.uturn.backward")
                    .font(.caption)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .cornerRadius(8)
            }
            .disabled(routeEngine.isSimulating || routeEngine.waypoints.isEmpty)

            // Segment custom speed sheet button
            Button(action: {
                showSegmentSheet = true
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                    Text("Đoạn (\(routeEngine.segments.count))")
                }
                .font(.caption)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(Color.blue.opacity(0.12))
                .foregroundColor(.blue)
                .cornerRadius(8)
            }
            .disabled(routeEngine.waypoints.count < 2)
            .sheet(isPresented: $showSegmentSheet) {
                SegmentSpeedSheet(routeEngine: routeEngine)
            }

            Spacer()

            // Start / Pause / Resume button
            if !routeEngine.isSimulating {
                Button(action: {
                    routeEngine.startSimulation()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Chạy")
                    }
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 16)
                    .background(routeEngine.waypoints.count >= 2 ? Color.green : Color.gray)
                    .cornerRadius(8)
                }
                .disabled(routeEngine.waypoints.count < 2)
            } else {
                Button(action: {
                    if routeEngine.isPaused {
                        routeEngine.resumeSimulation()
                    } else {
                        routeEngine.pauseSimulation()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: routeEngine.isPaused ? "play.fill" : "pause.fill")
                        Text(routeEngine.isPaused ? "Tiếp tục" : "Tạm dừng")
                    }
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 14)
                    .background(routeEngine.isPaused ? Color.green : Color.orange)
                    .cornerRadius(8)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000.0)
        } else {
            return "\(Int(meters)) m"
        }
    }

    // MARK: - Simulation Helper
    private func startSingleSimulation(at coordinate: CLLocationCoordinate2D, altitude: Double) {
        self.lat = coordinate.latitude
        self.long = coordinate.longitude

        let location = CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: 4.0,
            verticalAccuracy: 4.0,
            timestamp: Date()
        )
        LocSimManager.startLocSim(location: location)

        AlertKitAPI.present(
            title: "Đã bật GPS!",
            icon: .done,
            style: .iOS17AppleMusic,
            haptic: .success
        )
    }

    private func stopAllSimulation() {
        routeEngine.stopSimulation()
        LocSimManager.stopLocSim()
    }

    // MARK: - Alert Dialogs
    private func showManualCoordAlert() {
        UIApplication.shared.TextFieldAlert(
            title: "Nhập tọa độ",
            message: "Vị trí sẽ được mô phỏng trên toàn hệ thống.\n(Mẹo: Nhấn bất kỳ đâu trên bản đồ để bay tới)",
            textFieldPlaceHolder: "Vĩ độ (Latitude)",
            secondTextFieldPlaceHolder: "Kinh độ (Longitude)"
        ) { latText, longText in
            if let latDouble = Double(latText ?? ""), let longDouble = Double(longText ?? "") {
                let coordinate = CLLocationCoordinate2D(latitude: latDouble, longitude: longDouble)
                let altitudeValue = Double(altitude) ?? 0.0
                if mode == .single {
                    startSingleSimulation(at: coordinate, altitude: altitudeValue)
                } else {
                    routeEngine.addWaypoint(coordinate)
                }
            } else {
                UIApplication.shared.alert(body: "Tọa độ không hợp lệ!")
            }
        }
    }

    private func showAltitudeAlert() {
        UIApplication.shared.TextFieldAlert(
            title: "Cài đặt độ cao",
            message: "Nhập độ cao theo đơn vị mét.",
            textFieldPlaceHolder: "Độ cao (m)"
        ) { altitudeText, _ in
            if let altText = altitudeText, !altText.isEmpty {
                self.altitude = altText
                self.routeEngine.simulationAltitude = Double(altText) ?? 0.0
                if mode == .single && (lat != 0.0 || long != 0.0) {
                    let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: long)
                    startSingleSimulation(at: coordinate, altitude: Double(altText) ?? 0.0)
                }
            }
        }
    }
}

// MARK: - Segment Speed Configuration Sheet
struct SegmentSpeedSheet: View {
    @ObservedObject var routeEngine: RouteSimulationEngine
    @Environment(\.presentationMode) var presentationMode

    @State private var selectedSegmentIndices: Set<Int> = []
    @State private var targetSpeed: Double = 40.0
    @State private var targetVariance: Double = 5.0

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Top Selection Controls
                HStack {
                    Button(selectedSegmentIndices.count == routeEngine.segments.count ? "Bỏ chọn" : "Chọn tất cả") {
                        if selectedSegmentIndices.count == routeEngine.segments.count {
                            selectedSegmentIndices.removeAll()
                        } else {
                            selectedSegmentIndices = Set(routeEngine.segments.map { $0.id })
                        }
                    }
                    .font(.subheadline)

                    Spacer()

                    Text("Tổng cộng: \(routeEngine.segments.count) đoạn")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(UIColor.systemGroupedBackground))

                List {
                    ForEach(routeEngine.segments) { seg in
                        HStack(spacing: 12) {
                            Image(systemName: selectedSegmentIndices.contains(seg.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedSegmentIndices.contains(seg.id) ? .blue : .gray)
                                .font(.title3)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Đoạn \(seg.startIndex) ➔ \(seg.endIndex)")
                                        .font(.headline)
                                    Spacer()
                                    Text(formatDistance(seg.distanceMeters))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }

                                HStack(spacing: 6) {
                                    let speed = seg.customSpeedKmh ?? routeEngine.globalBaseSpeedKmh
                                    let variance = seg.customVarianceKmh ?? routeEngine.globalSpeedVarianceKmh
                                    let isCustom = seg.customSpeedKmh != nil

                                    Text("\(Int(speed)) ± \(Int(variance)) km/h")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(isCustom ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15))
                                        .foregroundColor(isCustom ? .blue : .secondary)
                                        .cornerRadius(4)

                                    if isCustom {
                                        Text("Riêng")
                                            .font(.caption2.bold())
                                            .foregroundColor(.blue)
                                    }

                                    if seg.isSharpTurn {
                                        Text("Khúc cua (Giảm 40%)")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.15))
                                            .foregroundColor(.orange)
                                            .cornerRadius(4)
                                    }
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedSegmentIndices.contains(seg.id) {
                                selectedSegmentIndices.remove(seg.id)
                            } else {
                                selectedSegmentIndices.insert(seg.id)
                            }
                        }
                    }
                }
                .listStyle(.plain)

                VStack(spacing: 10) {
                    Text(selectedSegmentIndices.isEmpty ? "Chọn đoạn ở trên để điều chỉnh" : "Đã chọn \(selectedSegmentIndices.count) đoạn")
                        .font(.subheadline.bold())
                        .foregroundColor(selectedSegmentIndices.isEmpty ? .secondary : .primary)

                    HStack {
                        Text("Tốc độ:")
                            .font(.caption.bold())
                        Button("- 5") { targetSpeed = max(10, targetSpeed - 5) }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray5))
                            .cornerRadius(4)

                        Slider(value: $targetSpeed, in: 10...120, step: 1)

                        Button("+ 5") { targetSpeed = min(120, targetSpeed + 5) }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray5))
                            .cornerRadius(4)

                        Text("\(Int(targetSpeed)) km/h")
                            .font(.caption.bold())
                            .frame(width: 55, alignment: .trailing)
                    }

                    HStack {
                        Text("Độ lệch:")
                            .font(.caption.bold())
                        Button("- 1") { targetVariance = max(0, targetVariance - 1) }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray5))
                            .cornerRadius(4)

                        Slider(value: $targetVariance, in: 0...15, step: 1)

                        Button("+ 1") { targetVariance = min(15, targetVariance + 1) }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray5))
                            .cornerRadius(4)

                        Text("±\(Int(targetVariance)) km/h")
                            .font(.caption.bold())
                            .frame(width: 55, alignment: .trailing)
                    }

                    HStack(spacing: 12) {
                        Button("Khôi phục mặc định") {
                            routeEngine.setSpeedForSegments(indices: selectedSegmentIndices, speedKmh: nil, varianceKmh: nil)
                            selectedSegmentIndices.removeAll()
                        }
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                        .disabled(selectedSegmentIndices.isEmpty)

                        Button("Áp dụng tốc độ") {
                            routeEngine.setSpeedForSegments(indices: selectedSegmentIndices, speedKmh: targetSpeed, varianceKmh: targetVariance)
                            selectedSegmentIndices.removeAll()
                        }
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(selectedSegmentIndices.isEmpty ? Color.gray : Color.blue)
                        .cornerRadius(8)
                        .disabled(selectedSegmentIndices.isEmpty)
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground).shadow(radius: 4))
            }
            .navigationTitle("Tốc độ từng đoạn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Text("Xong")
                            .bold()
                    }
                }
            }
        }
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000.0)
        } else {
            return "\(Int(meters)) m"
        }
    }
}

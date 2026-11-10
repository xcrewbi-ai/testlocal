//
//  LocSimView.swift
//  Geranium (CompassPro)
//
//  Modernized Fake GPS with Route Simulation:
//  - Interactive Preview Pin for Search & Bookmarks before confirming
//  - Reliable Bookmarks Manager (Save fake GPS, Route Waypoints, Search Places)
//  - Compass clearance on top right (search bar shortened)
//  - Bigger, prominent function buttons & Master Stop GPS button
//  - Centered 1.5x Large "ĐÃ DỪNG GPS!" alert
//  - Clean dialogs with no hint text
//  - Zero UI freezing & Smart Road Routing (Apple Maps Directions)
//

import SwiftUI
import CoreLocation
import MapKit
import AlertKit

enum LocSimMode: String, CaseIterable, Identifiable {
    case single = "Điểm đơn"
    case route = "Lộ trình"

    var id: String { self.rawValue }
}

final class LocationSearchManager: ObservableObject {
    @Published var query: String = ""
    @Published var searchResults: [MKMapItem] = []
    @Published var isSearching: Bool = false
    private var searchTask: DispatchWorkItem?

    func search(_ text: String) {
        query = text
        searchTask?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        let task = DispatchWorkItem { [weak self] in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = trimmed
            let localSearch = MKLocalSearch(request: request)
            localSearch.start { response, error in
                DispatchQueue.main.async {
                    self?.isSearching = false
                    self?.searchResults = response?.mapItems ?? []
                }
            }
        }
        searchTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }

    func dismissResults() {
        searchResults = []
        isSearching = false
        searchTask?.cancel()
    }

    func clear() {
        query = ""
        searchResults = []
        isSearching = false
        searchTask?.cancel()
    }
}

struct LocSimView: View {
    @StateObject private var appSettings = AppSettings()
    @StateObject private var routeEngine = RouteSimulationEngine.shared
    @StateObject private var searchManager = LocationSearchManager()
    @StateObject private var bookmarkManager = BookmarkManager.shared

    @FocusState private var isSearchFocused: Bool

    @State private var mode: LocSimMode = .single
    @State private var lat: Double = 0.0
    @State private var long: Double = 0.0
    @State private var altitude: String = "0.0"
    @State private var tappedCoordinate: EquatableCoordinate? = nil
    @State private var mapCenterCoord: EquatableCoordinate? = nil

    // Preview Pin State (for search & bookmarks before confirmation)
    @State private var previewCoordinate: CLLocationCoordinate2D? = nil
    @State private var previewTitle: String = ""

    @State private var bookmarkSheetTggle: Bool = false
    @State private var showSegmentSheet: Bool = false
    @State private var showCenteredStopAlert: Bool = false

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                mainContainer
            }
        } else {
            NavigationView {
                mainContainer
            }
        }
    }

    @ViewBuilder
    private var mainContainer: some View {
        ZStack(alignment: .top) {
            // Interactive MapKit View
            CustomMapView(
                tappedCoordinate: $tappedCoordinate,
                centerCoordinate: $mapCenterCoord,
                isRouteMode: mode == .route,
                waypoints: routeEngine.waypoints,
                pathCoordinates: routeEngine.allPathCoordinates,
                currentSimulatedCoord: routeEngine.currentCoordinate,
                previewCoord: previewCoordinate
            )
            .ignoresSafeArea(edges: .bottom)
            .onAppear {
                LocationModel().requestAuthorisation()
            }

            // Transparent Tap-To-Dismiss Overlay: Tapping outside search dismisses keyboard without selecting map point
            if isSearchFocused || !searchManager.searchResults.isEmpty {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        isSearchFocused = false
                        searchManager.dismissResults()
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
            }

            // Top Floating Search Bar (shortened on the right for Map Compass button clearance)
            VStack(spacing: 8) {
                searchBarView

                if isSearchFocused && !searchManager.searchResults.isEmpty {
                    searchResultsDropdown
                }
            }
            .padding(.top, 8)

            // Bottom Overlays: Preview Confirmation Card OR Route Control Panel
            VStack {
                Spacer()

                if let previewCoord = previewCoordinate {
                    previewConfirmationCard(coordinate: previewCoord)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if mode == .route {
                    RouteControlPanel()
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }

            // Centered 1.5x Large Stop GPS Alert
            if showCenteredStopAlert {
                centeredStopAlertView
            }
        }
        .onChange(of: tappedCoordinate) { newValue in
            guard let coord = newValue?.coordinate else { return }
            searchManager.dismissResults()

            if previewCoordinate != nil {
                // If a preview pin is currently active, tapping moves the preview pin!
                previewCoordinate = coord
            } else if mode == .single {
                let altitudeValue = Double(altitude) ?? 0.0
                startSingleSimulation(at: coord, altitude: altitudeValue)
            } else {
                routeEngine.addWaypoint(coord)
            }
        }
        .onChange(of: altitude) { newAlt in
            routeEngine.simulationAltitude = Double(newAlt) ?? 0.0
        }
        .sheet(isPresented: $bookmarkSheetTggle) {
            BookMarkSlider(
                currentFakeCoord: routeEngine.currentCoordinate,
                waypoints: routeEngine.waypoints
            ) { selectedBm in
                previewCoordinate = selectedBm.coordinate
                previewTitle = selectedBm.name
                mapCenterCoord = EquatableCoordinate(coordinate: selectedBm.coordinate)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Picker("Chế độ", selection: $mode) {
                    ForEach(LocSimMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 175)
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 8) {
                    // Manual coordinate entry
                    Button(action: showManualCoordAlert) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.blue)
                            .frame(width: 34, height: 34)
                            .background(Color(.systemGray6))
                            .clipShape(Circle())
                    }

                    // Altitude setting
                    Button(action: showAltitudeAlert) {
                        Image(systemName: "mountain.2.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.blue)
                            .frame(width: 34, height: 34)
                            .background(Color(.systemGray6))
                            .clipShape(Circle())
                    }

                    // Bookmarks
                    Button(action: {
                        bookmarkSheetTggle = true
                    }) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.blue)
                            .frame(width: 34, height: 34)
                            .background(Color(.systemGray6))
                            .clipShape(Circle())
                    }

                    // Master Stop Simulation button: Prominent circular button with stop square icon
                    Button(action: {
                        stopAllSimulation()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            showCenteredStopAlert = true
                        }
                    }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.red)
                            .clipShape(Circle())
                            .shadow(color: Color.red.opacity(0.35), radius: 3, x: 0, y: 1)
                    }
                }
            }
        }
    }

    // MARK: - Search Bar Views (Shortened on right for Compass Button clearance)
    private var searchBarView: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.blue)
                .font(.system(size: 15, weight: .semibold))

            TextField("Tìm địa điểm, địa chỉ...", text: $searchManager.query)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.subheadline)
                .focused($isSearchFocused)
                .onChange(of: searchManager.query) { newText in
                    searchManager.search(newText)
                }
                .onChange(of: isSearchFocused) { focused in
                    if focused && !searchManager.query.isEmpty && searchManager.searchResults.isEmpty {
                        searchManager.search(searchManager.query)
                    }
                }

            if searchManager.isSearching {
                ProgressView()
                    .scaleEffect(0.7)
            } else if !searchManager.query.isEmpty {
                Button(action: {
                    searchManager.clear()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.14), radius: 6, x: 0, y: 3)
        )
        .padding(.leading, 16)
        .padding(.trailing, 68) // Clearance for map compass button!
    }

    private var searchResultsDropdown: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(searchManager.searchResults, id: \.self) { item in
                    Button(action: {
                        selectSearchResult(item)
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title3)
                                .foregroundColor(.blue)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "Địa điểm")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.primary)
                                    .lineLimit(1)

                                let subtitle = [
                                    item.placemark.subThoroughfare,
                                    item.placemark.thoroughfare,
                                    item.placemark.subLocality,
                                    item.placemark.locality,
                                    item.placemark.administrativeArea
                                ].compactMap { $0 }.joined(separator: ", ")

                                if !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            Image(systemName: "arrow.up.left")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    Divider().padding(.horizontal, 14)
                }
            }
        }
        .frame(maxHeight: 220)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
        )
        .padding(.leading, 16)
        .padding(.trailing, 68)
    }

    private func selectSearchResult(_ item: MKMapItem) {
        let coord = item.placemark.coordinate
        mapCenterCoord = EquatableCoordinate(coordinate: coord)
        previewCoordinate = coord
        previewTitle = item.name ?? "Địa điểm đã chọn"
        isSearchFocused = false
        searchManager.clear()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: - Preview Pin Confirmation Card
    @ViewBuilder
    private func previewConfirmationCard(coordinate: CLLocationCoordinate2D) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.title3)
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 1) {
                    Text(previewTitle.isEmpty ? "Vị trí đã chọn" : previewTitle)
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    withAnimation {
                        previewCoordinate = nil
                        previewTitle = ""
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button("Hủy") {
                    withAnimation {
                        previewCoordinate = nil
                        previewTitle = ""
                    }
                }
                .font(.caption.bold())
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .background(Color(.systemGray5))
                .foregroundColor(.primary)
                .cornerRadius(8)

                Button(action: {
                    confirmPreviewPin(at: coordinate)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: mode == .single ? "location.fill" : "plus.circle.fill")
                        Text(mode == .single ? "Xác nhận Fake GPS" : "Thêm vào lộ trình")
                    }
                    .font(.caption.bold())
                    .padding(.vertical, 7)
                    .padding(.horizontal, 14)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
        )
    }

    private func confirmPreviewPin(at coordinate: CLLocationCoordinate2D) {
        let name = previewTitle.isEmpty ? "Vị trí đã chọn" : previewTitle
        withAnimation {
            previewCoordinate = nil
            previewTitle = ""
        }

        if mode == .single {
            let altitudeValue = Double(altitude) ?? 0.0
            startSingleSimulation(at: coordinate, altitude: altitudeValue)
            AlertKitAPI.present(
                title: "Đã tới \(name)",
                icon: .done,
                style: .iOS17AppleMusic,
                haptic: .success
            )
        } else {
            routeEngine.addWaypoint(coordinate)
            AlertKitAPI.present(
                title: "Đã thêm \(name)",
                icon: .done,
                style: .iOS17AppleMusic,
                haptic: .success
            )
        }
    }

    // MARK: - Route Floating Control Panel (Compact & Modern)
    @ViewBuilder
    private func RouteControlPanel() -> some View {
        VStack(spacing: 5) {
            // Stats Header: Speed, Distance, ETA, Waypoints, Road/Straight & Loop
            statsHeaderRow

            // Live Speed Slider Row (Zero-Freeze)
            liveSpeedSliderRow

            // Progress bar
            if routeEngine.isSimulating {
                ProgressView(value: routeEngine.progressPercent)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                    .scaleEffect(x: 1, y: 0.8)
                    .padding(.horizontal, 10)
            }

            // Compact Action Buttons Row
            actionButtonsRow
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
        )
    }

    private var statsHeaderRow: some View {
        HStack(spacing: 8) {
            // Live Speed
            HStack(spacing: 2) {
                Text(String(format: "%.0f", routeEngine.currentSpeedKmh))
                    .font(.subheadline.bold())
                Text("km/h")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider().frame(height: 14)

            // Distance & count
            HStack(spacing: 2) {
                Text(formatDistance(routeEngine.totalDistanceMeters))
                    .font(.caption.bold())
                Text("(\(routeEngine.waypoints.count)đ)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // ETA info (if >= 2 waypoints)
            if routeEngine.waypoints.count >= 2 {
                Divider().frame(height: 14)
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                    Text(routeEngine.etaFormattedDuration)
                        .font(.caption.bold())
                        .foregroundColor(.primary)
                    Text("(\(routeEngine.etaArrivalTimeString))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 4)

            // Auto-routing toggle
            Button(action: {
                routeEngine.isAutoRouting.toggle()
            }) {
                HStack(spacing: 2) {
                    Image(systemName: routeEngine.isAutoRouting ? "car.fill" : "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 11, weight: .semibold))
                    Text(routeEngine.isAutoRouting ? "Đường" : "Thẳng")
                        .font(.caption2.bold())
                    if routeEngine.isCalculatingRoute {
                        ProgressView().scaleEffect(0.5)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(routeEngine.isAutoRouting ? Color.blue.opacity(0.18) : Color(.systemGray5))
                .foregroundColor(routeEngine.isAutoRouting ? .blue : .primary)
                .cornerRadius(6)
            }

            // Loop toggle
            Button(action: {
                routeEngine.isLooping.toggle()
            }) {
                Image(systemName: routeEngine.isLooping ? "repeat.1" : "repeat")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(5)
                    .background(routeEngine.isLooping ? Color.blue.opacity(0.2) : Color(.systemGray5))
                    .foregroundColor(routeEngine.isLooping ? .blue : .primary)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    // Zero-freeze speed controls using direct bindings
    private var liveSpeedSliderRow: some View {
        HStack(spacing: 6) {
            Button(action: {
                routeEngine.setGlobalSpeedKmh(routeEngine.globalBaseSpeedKmh - 5)
            }) {
                Text("-5")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(.systemGray5))
                    .cornerRadius(4)
            }

            Slider(
                value: Binding(
                    get: { routeEngine.globalBaseSpeedKmh },
                    set: { routeEngine.setGlobalSpeedKmh($0) }
                ),
                in: 10...120,
                step: 1
            )

            Button(action: {
                routeEngine.setGlobalSpeedKmh(routeEngine.globalBaseSpeedKmh + 5)
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
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 10)
    }

    private var actionButtonsRow: some View {
        HStack(spacing: 6) {
            // Nút chuyển đổi Xóa / Hoàn thành:
            if routeEngine.isSimulating {
                Button(action: {
                    routeEngine.completeRouteAndClear()
                    AlertKitAPI.present(
                        title: "Đã hoàn thành!",
                        icon: .done,
                        style: .iOS17AppleMusic,
                        haptic: .success
                    )
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "flag.checkered")
                            .font(.system(size: 12, weight: .bold))
                        Text("Hoàn thành")
                    }
                    .font(.caption.bold())
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            } else {
                Button(action: {
                    routeEngine.clearRoute()
                    AlertKitAPI.present(
                        title: "Đã xóa tuyến đường!",
                        icon: .done,
                        style: .iOS17AppleMusic,
                        haptic: .success
                    )
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Xóa")
                    }
                    .font(.caption.bold())
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(Color(.systemGray5))
                    .foregroundColor(.red)
                    .cornerRadius(8)
                }
                .disabled(routeEngine.waypoints.isEmpty)
            }

            // Undo last point
            Button(action: {
                routeEngine.removeLastWaypoint()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Lùi")
                }
                .font(.caption)
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .background(Color(.systemGray5))
                .foregroundColor(.primary)
                .cornerRadius(8)
            }
            .disabled(routeEngine.waypoints.isEmpty || (routeEngine.isSimulating && routeEngine.waypoints.count <= routeEngine.currentSegmentIndex + 2))

            // Segment custom speed sheet button
            Button(action: {
                showSegmentSheet = true
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "speedometer")
                    Text("Đoạn (\(routeEngine.segments.count))")
                }
                .font(.caption)
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
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
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                        Text("Chạy")
                    }
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 14)
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
                    .padding(.horizontal, 10)
                    .background(routeEngine.isPaused ? Color.green : Color.orange)
                    .cornerRadius(8)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000.0)
        } else {
            return "\(Int(meters)) m"
        }
    }

    // MARK: - Centered 1.5x Large Stop GPS Alert
    private var centeredStopAlertView: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showCenteredStopAlert = false
                    }
                }

            VStack(spacing: 16) {
                Image(systemName: "location.slash.fill")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundColor(.red)

                Text("ĐÃ DỪNG GPS!")
                    .font(.system(size: 24, weight: .black))
                    .foregroundColor(.primary)

                Text("Đã tắt giả lập và trả về vị trí GPS thực tế của thiết bị.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 32)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(UIColor.systemBackground))
                    .shadow(color: Color.black.opacity(0.35), radius: 25, x: 0, y: 12)
            )
            .scaleEffect(showCenteredStopAlert ? 1.0 : 0.8)
            .transition(.scale.combined(with: .opacity))
        }
        .zIndex(999)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showCenteredStopAlert = false
                }
            }
        }
    }

    // MARK: - Simulation Triggers
    private func startSingleSimulation(at coordinate: CLLocationCoordinate2D, altitude: Double) {
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

    // MARK: - Alert Dialogs (Clean with NO hint text)
    private func showManualCoordAlert() {
        UIApplication.shared.TextFieldAlert(
            title: "Nhập tọa độ",
            message: nil,
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
                UIApplication.shared.alert(title: "Lỗi", body: "Tọa độ không hợp lệ!")
            }
        }
    }

    private func showAltitudeAlert() {
        UIApplication.shared.TextFieldAlert(
            title: "Cài đặt độ cao",
            message: nil,
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
                            presentationMode.wrappedValue.dismiss()
                        }
                        .font(.subheadline)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .cornerRadius(8)

                        Spacer()

                        Button("Áp dụng") {
                            routeEngine.setSpeedForSegments(indices: selectedSegmentIndices, speedKmh: targetSpeed, varianceKmh: targetVariance)
                            selectedSegmentIndices.removeAll()
                            presentationMode.wrappedValue.dismiss()
                        }
                        .font(.subheadline.bold())
                        .padding(.vertical, 8)
                        .padding(.horizontal, 18)
                        .background(selectedSegmentIndices.isEmpty ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .disabled(selectedSegmentIndices.isEmpty)
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
            }
            .navigationTitle("Tốc độ từng đoạn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") {
                        presentationMode.wrappedValue.dismiss()
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

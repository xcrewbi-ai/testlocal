//
//  BookMarkSlider.swift
//  Geranium (CompassPro)
//
//  Modern, High-Performance Bookmark Manager Sheet with Live Search & Quick Point Saver.
//

import Foundation
import SwiftUI
import MapKit
import AlertKit

struct BookMarkSlider: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var bookmarkManager = BookmarkManager.shared

    var currentFakeCoord: CLLocationCoordinate2D?
    var waypoints: [RouteWaypoint]
    var onSelect: (SavedBookmark) -> Void

    @State private var searchQuery: String = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching: Bool = false
    @State private var searchTask: DispatchWorkItem?

    var body: some View {
        NavigationView {
            List {
                // Section 1: Search new place to bookmark
                Section(header: Text("Tìm địa điểm để lưu")) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Nhập tên địa điểm hoặc địa chỉ...", text: $searchQuery)
                            .onChange(of: searchQuery) { newText in
                                performSearch(newText)
                            }
                        if isSearching {
                            ProgressView().scaleEffect(0.7)
                        } else if !searchQuery.isEmpty {
                            Button(action: {
                                searchQuery = ""
                                searchResults = []
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if !searchResults.isEmpty {
                        ForEach(searchResults, id: \.self) { item in
                            HStack {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundColor(.blue)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? "Địa điểm")
                                        .font(.subheadline.bold())
                                    let subtitle = [
                                        item.placemark.thoroughfare,
                                        item.placemark.subLocality,
                                        item.placemark.locality
                                    ].compactMap { $0 }.joined(separator: ", ")
                                    if !subtitle.isEmpty {
                                        Text(subtitle)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }

                                Spacer()

                                Button(action: {
                                    saveFromSearch(item)
                                }) {
                                    Text("Lưu")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        }
                    }
                }

                // Section 2: Quick save active positions
                if currentFakeCoord != nil || !waypoints.isEmpty {
                    Section(header: Text("Lưu vị trí đang hoạt động")) {
                        if let fakeCoord = currentFakeCoord {
                            HStack {
                                Image(systemName: "location.fill")
                                    .foregroundColor(.green)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Vị trí GPS đang fake")
                                        .font(.subheadline.bold())
                                    Text(String(format: "%.5f, %.5f", fakeCoord.latitude, fakeCoord.longitude))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Button(action: {
                                    promptSave(coord: fakeCoord, defaultName: "Vị trí đang fake")
                                }) {
                                    Text("Lưu")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.green)
                                        .foregroundColor(.white)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        }

                        ForEach(waypoints) { wp in
                            HStack {
                                Image(systemName: "flag.fill")
                                    .foregroundColor(.orange)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Điểm \(wp.order) trong lộ trình")
                                        .font(.subheadline.bold())
                                    Text(String(format: "%.5f, %.5f", wp.coordinate.latitude, wp.coordinate.longitude))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Button(action: {
                                    promptSave(coord: wp.coordinate, defaultName: "Điểm \(wp.order)")
                                }) {
                                    Text("Lưu")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.orange)
                                        .foregroundColor(.white)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        }
                    }
                }

                // Section 3: Saved bookmarks list
                Section(header: Text("Địa điểm đã lưu (\(bookmarkManager.bookmarks.count))")) {
                    if bookmarkManager.bookmarks.isEmpty {
                        Text("Chưa có địa điểm nào được lưu.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(bookmarkManager.bookmarks) { bm in
                            Button(action: {
                                onSelect(bm)
                                presentationMode.wrappedValue.dismiss()
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "bookmark.circle.fill")
                                        .font(.title2)
                                        .foregroundColor(.blue)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(bm.name)
                                            .font(.headline)
                                            .foregroundColor(.primary)

                                        if let sub = bm.subtitle, !sub.isEmpty {
                                            Text(sub)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }

                                        Text(String(format: "%.5f, %.5f", bm.latitude, bm.longitude))
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                        }
                        .onDelete(perform: bookmarkManager.deleteBookmark)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Địa điểm đã lưu")
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

    private func performSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        let task = DispatchWorkItem {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = trimmed
            let search = MKLocalSearch(request: request)
            search.start { response, _ in
                DispatchQueue.main.async {
                    self.isSearching = false
                    self.searchResults = response?.mapItems ?? []
                }
            }
        }
        searchTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }

    private func saveFromSearch(_ item: MKMapItem) {
        let name = item.name ?? "Địa điểm mới"
        let coord = item.placemark.coordinate
        let subtitle = [item.placemark.locality, item.placemark.administrativeArea].compactMap { $0 }.joined(separator: ", ")

        bookmarkManager.addBookmark(name: name, coordinate: coord, subtitle: subtitle)
        searchQuery = ""
        searchResults = []

        AlertKitAPI.present(
            title: "Đã lưu vào Bookmark!",
            icon: .done,
            style: .iOS17AppleMusic,
            haptic: .success
        )
    }

    private func promptSave(coord: CLLocationCoordinate2D, defaultName: String) {
        UIApplication.shared.TextFieldAlert(
            title: "Đặt tên địa điểm",
            message: nil,
            textFieldPlaceHolder: defaultName
        ) { enteredText, _ in
            let name = (enteredText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? enteredText! : defaultName
            self.bookmarkManager.addBookmark(name: name, coordinate: coord)
            AlertKitAPI.present(
                title: "Đã lưu vào Bookmark!",
                icon: .done,
                style: .iOS17AppleMusic,
                haptic: .success
            )
        }
    }
}

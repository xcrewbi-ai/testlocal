//
//  BookMarkHelper.swift
//  Geranium (CompassPro)
//
//  High-reliability bookmark manager compatible with all sideload methods (SideStore, AltStore, TrollStore).
//

import Foundation
import CoreLocation
import SwiftUI

let sharedUserDefaultsSuiteName = "group.live.cclerc.geraniumBookmarks"

struct SavedBookmark: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var dateAdded: Date = Date()
    var subtitle: String? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

final class BookmarkManager: ObservableObject {
    static let shared = BookmarkManager()
    private let storageKey = "com.compasspro.bookmarks.saved"

    @Published var bookmarks: [SavedBookmark] = []

    private var storageDefaults: UserDefaults {
        UserDefaults(suiteName: sharedUserDefaultsSuiteName) ?? UserDefaults.standard
    }

    init() {
        loadBookmarks()
    }

    func loadBookmarks() {
        // Try modern JSON storage
        if let data = storageDefaults.data(forKey: storageKey),
           let list = try? JSONDecoder().decode([SavedBookmark].self, from: data) {
            self.bookmarks = list
            return
        }
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let list = try? JSONDecoder().decode([SavedBookmark].self, from: data) {
            self.bookmarks = list
            return
        }

        // Check legacy plist array storage
        let legacy = BookMarkRetrieve()
        if !legacy.isEmpty {
            self.bookmarks = legacy.compactMap { dict in
                guard let name = dict["name"] as? String,
                      let lat = dict["lat"] as? Double,
                      let long = dict["long"] as? Double else { return nil }
                return SavedBookmark(name: name, latitude: lat, longitude: long)
            }
            saveBookmarks()
        }
    }

    func addBookmark(name: String, coordinate: CLLocationCoordinate2D, subtitle: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Vị trí đã lưu" : trimmed
        let newBm = SavedBookmark(
            name: finalName,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            dateAdded: Date(),
            subtitle: subtitle
        )
        bookmarks.insert(newBm, at: 0)
        saveBookmarks()
    }

    func deleteBookmark(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        saveBookmarks()
    }

    func deleteBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        saveBookmarks()
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            storageDefaults.set(data, forKey: storageKey)
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// MARK: - Legacy Compatibility APIs
func BookMarkSave(lat: Double, long: Double, name: String) -> Bool {
    BookmarkManager.shared.addBookmark(name: name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: long))
    return true
}

func BookMarkRetrieve() -> [[String: Any]] {
    let defaults = UserDefaults(suiteName: sharedUserDefaultsSuiteName) ?? UserDefaults.standard
    if let bookmarks = defaults.array(forKey: "bookmarks") as? [[String: Any]] {
        return bookmarks
    }
    return []
}

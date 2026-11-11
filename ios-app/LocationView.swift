//
//  LocationView.swift
//  CompassPro
//

import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

enum DeveloperDiskImage {
    private static let baseURL =
        "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized"

    private static let files = [
        "BuildManifest.plist",
        "Image.dmg",
        "Image.dmg.trustcache",
    ]

    static var directory: URL {
        URL.documentsDirectory.appendingPathComponent("DDI", isDirectory: true)
    }

    static var imagePath: String { directory.appendingPathComponent("Image.dmg").path }
    static var trustcachePath: String { directory.appendingPathComponent("Image.dmg.trustcache").path }
    static var manifestPath: String { directory.appendingPathComponent("BuildManifest.plist").path }

    static var isDownloaded: Bool {
        files.allSatisfy { name in
            let path = directory.appendingPathComponent(name).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return size > 0
        }
    }

    static func prepareLocalDDI(progress: @escaping (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 1. Copy from app bundle if bundled
        let bundleDDI = Bundle.main.bundleURL.appendingPathComponent("DDI", isDirectory: true)
        for name in files {
            let dest = directory.appendingPathComponent(name)
            let destAttr = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let destSize = (destAttr?[.size] as? NSNumber)?.int64Value ?? 0
            if destSize == 0 {
                let bundledFile = bundleDDI.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: bundledFile.path) {
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.copyItem(at: bundledFile, to: dest)
                } else if let resourceURL = Bundle.main.url(forResource: name, withExtension: nil) {
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.copyItem(at: resourceURL, to: dest)
                }
            }
        }

        if isDownloaded {
            Engine.shared.log("DDI files are ready in Documents/DDI.")
            progress(1.0)
            return
        }

        // 2. Download missing files from GitHub mirror if not bundled
        try await downloadMissing(progress: progress)
    }

    static func downloadMissing(progress: @escaping (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let missing = files.filter { name in
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        guard !missing.isEmpty else { progress(1); return }

        for (index, name) in missing.enumerated() {
            progress(Double(index) / Double(missing.count))
            guard let url = URL(string: "\(baseURL)/\(name)") else {
                throw EngineError.message(L("Couldn't build the download URL for %@.", name))
            }
            let (tmp, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw EngineError.message(L("Downloading %@ failed (HTTP %d).", name, code))
            }
            let destination = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmp, to: destination)
            Engine.shared.log("DDI: downloaded \(name).")
        }
        progress(1)
    }
}

final class LocationManager: ObservableObject {
    @Published var isBusy = false
    @Published var lastError: String?
    @Published var lastSuccess: String?
    @Published var simulated: CLLocationCoordinate2D?
    
    var popups: [ToolPopup] {
        [lastError.map(ToolPopup.error), lastSuccess.map(ToolPopup.success)].compactMap { $0 }
    }

    func closePopup(_ popup: ToolPopup) {
        switch popup {
        case .error:   lastError = nil
        case .success: lastSuccess = nil
        }
    }
}

struct LocationView: View {
    @ObservedObject var manager: LocationManager
    
    init(manager: LocationManager? = nil) {
        self.manager = manager ?? LocationManager()
    }
    
    var body: some View {
        LocSimView()
    }
}

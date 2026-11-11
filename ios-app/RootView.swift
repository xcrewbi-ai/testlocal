import SwiftUI

/// Tab container (Compass GPS & Pairing).
struct RootView: View {
    private enum Page: Hashable {
        case compass, pairing

        var wash: Backdrop.Level {
            switch self {
            case .compass: .bright
            case .pairing: .bright
            }
        }
    }

    @Environment(Engine.self) private var engine
    @State private var page: Page = .compass

    var body: some View {
        TabView(selection: tabSelection) {
            LocSimView()
                .tabItem { Label("La bàn GPS", systemImage: "safari.fill") }
                .tag(Page.compass)

            NavigationStack {
                PairingView()
            }
            .tabItem { Label("Ghép đôi", systemImage: "link.badge.plus") }
            .tag(Page.pairing)
        }
        .onChange(of: page) { _, page in Backdrop.settle(on: page.wash) }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    private var tabSelection: Binding<Page> {
        Binding(
            get: { page },
            set: { newPage in
                if newPage != page { SoundEffects.play(.tick) }
                page = newPage
            }
        )
    }
}

// MARK: - Legacy ToolPopup compatibility
enum ToolPopup: Hashable {
    case error(String)
    case success(String)
}

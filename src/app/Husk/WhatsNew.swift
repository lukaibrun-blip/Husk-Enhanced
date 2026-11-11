// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

// MARK: - what's new

/// What this version brought, shown once after updating to it (not on a first install: onboarding is the welcome then).
enum WhatsNew {
    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    /// The version whose notes these are. A build of the same version shows nothing again.
    static let version = "3.4"
    static let items: [Item] = [
        Item(symbol: "shippingbox.fill", title: "More Android apps",
             detail: "Microsoft Word, Slack, Gmail, Teams, Deezer, Flipboard and Picsart get past the crashes that stopped them. React Native's new architecture and Qt 6 start, and libGDX and other OpenGL apps draw again."),
        Item(symbol: "paintbrush.fill", title: "Looks better",
             detail: "Rounded buttons are proper pills, and toolbars, window backgrounds and more color formats behave as they do on a phone."),
        Item(symbol: "memorychip", title: "Less \"out of memory\"",
             detail: "Fewer thread and address space crashes on sideloaded installs, and Unity games keep their frame rate up. Settings > Performance shows whether Increased Memory Limit and Extended Address Space are on."),
        Item(symbol: "globe", title: "Japanese",
             detail: "Husk is now in Japanese too, thanks to Yuki-1018."),
        Item(symbol: "wrench.and.screwdriver.fill", title: "Fixes",
             detail: "Importing a .p12, or launching with one saved, no longer crashes on iOS 27. Remove and Uninstall open next to their buttons on iPad, and Winlator's Settings no longer crashes."),
    ]

    private static let seenKey = "husk.whatsNew.seen"

    /// Whether to show the notes now: an update to this version, not a new install.
    static var due: Bool {
        let seen = UserDefaults.standard.string(forKey: seenKey)
        if seen == version { return false }
        if Onboarding.needed { markSeen(); return false }       // a first install: onboarding welcomes them
        return true
    }

    static func markSeen() { UserDefaults.standard.set(version, forKey: seenKey) }
}

struct WhatsNewSheet: View {
    var done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What's New in Husk \(WhatsNew.version)").font(.largeTitle.weight(.bold))
                    }
                    .padding(.top, 36)
                    ForEach(WhatsNew.items) { item in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 26))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.headline)
                                Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
            Button(action: done) {
                Text("Continue").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .interactiveDismissDisabled()
    }
}


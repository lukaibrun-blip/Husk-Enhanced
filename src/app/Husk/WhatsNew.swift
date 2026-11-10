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

// MARK: - a newer Husk

/// Checks the official Husk GitHub Releases endpoint. Checks are throttled to twice a day; failures only
/// update this optional status and never affect launching or running Husk.
@MainActor
final class AppUpdates: ObservableObject {
    static let shared = AppUpdates()

    struct Release: Equatable {
        let version: String
        let page: URL
        let ipa: URL?
        let summary: String

        var updateURL: URL { ipa ?? page }
    }

    @Published private(set) var available: Release?
    @Published private(set) var checking = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var dismissedVersion: String?

    private static let api = URL(string: "https://api.github.com/repos/Leviidev/Husk/releases/latest")!
    private static let checkedKey = "husk.updates.checked", dismissedKey = "husk.updates.dismissed"
    private static let checkInterval: TimeInterval = 12 * 60 * 60

    private init() {
        let defaults = UserDefaults.standard
        let lastCheck = defaults.double(forKey: Self.checkedKey)
        lastCheckedAt = lastCheck > 0 ? Date(timeIntervalSince1970: lastCheck) : nil
        dismissedVersion = defaults.string(forKey: Self.dismissedKey)
    }

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var shouldNotify: Bool { available != nil && available?.version != dismissedVersion }

    func check(force: Bool = false) async {
        guard !checking else { return }
        let defaults = UserDefaults.standard
        let now = Date()
        if !force, now.timeIntervalSince1970 - defaults.double(forKey: Self.checkedKey) < Self.checkInterval { return }

        checking = true
        statusMessage = nil
        errorMessage = nil
        defer { checking = false }

        do {
            var request = URLRequest(url: Self.api)
            request.timeoutInterval = 20
            request.setValue("Husk Enhanced", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CheckError.invalidResponse }
            guard http.statusCode == 200 else { throw CheckError.http(http.statusCode) }

            let result = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard !result.draft, !result.prerelease,
                  let version = AppUpdateSupport.normalizedVersion(result.tagName),
                  let page = Self.trustedURL(result.htmlURL, pathPrefix: "/Leviidev/Husk/releases/tag/") else {
                throw CheckError.unverifiedRelease
            }
            let ipa = result.assets.first(where: { $0.name.caseInsensitiveCompare("Husk.ipa") == .orderedSame })
                .flatMap { Self.trustedURL($0.browserDownloadURL, pathPrefix: "/Leviidev/Husk/releases/download/") }
            let summary = AppUpdateSupport.summary(from: result.body ?? "")
            let release = Release(version: version, page: page, ipa: ipa, summary: summary)

            defaults.set(now.timeIntervalSince1970, forKey: Self.checkedKey)
            lastCheckedAt = now
            if Self.newer(version, than: Self.current) {
                available = release
                statusMessage = "Version \(version) is available."
                HuskLog.log("update", "Husk \(version) is out (this is \(Self.current))")
            } else {
                available = nil
                statusMessage = "Husk is up to date."
            }
        } catch {
            guard !Task.isCancelled else { return }
            defaults.set(now.timeIntervalSince1970, forKey: Self.checkedKey)
            lastCheckedAt = now
            errorMessage = Self.message(for: error)
            HuskLog.log("update", "release check failed: \(error.localizedDescription)")
        }
    }

    func dismiss() {
        guard let version = available?.version else { return }
        UserDefaults.standard.set(version, forKey: Self.dismissedKey)
        dismissedVersion = version
    }

    /// "1.0.10" is newer than "1.0.9": compare numeric components, not strings.
    static func newer(_ a: String, than b: String) -> Bool {
        AppUpdateSupport.isNewer(a, than: b)
    }

    private static func trustedURL(_ raw: String, pathPrefix: String) -> URL? {
        guard let parts = URLComponents(string: raw),
              parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "github.com",
              parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil,
              parts.path.hasPrefix(pathPrefix) else { return nil }
        return parts.url
    }

    private static func message(for error: Error) -> String {
        if let error = error as? CheckError {
            switch error {
            case .http(403): return "GitHub temporarily limited update checks. Try again later."
            case .http(let code): return "GitHub Releases is unavailable (HTTP \(code)). Try again later."
            case .invalidResponse, .unverifiedRelease: return "Husk couldn't verify the release information from GitHub. Try again later."
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "No internet connection. Connect to Wi-Fi or cellular data and try again."
            case .timedOut:
                return "GitHub did not respond in time. Try again later."
            default:
                return "Couldn't check GitHub Releases: \(error.localizedDescription)"
            }
        }
        return "Couldn't read GitHub's release information: \(error.localizedDescription)"
    }

    private enum CheckError: Error {
        case http(Int)
        case invalidResponse
        case unverifiedRelease
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body, draft, prerelease, assets
        }

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            enum CodingKeys: String, CodingKey { case name; case browserDownloadURL = "browser_download_url" }
        }
    }
}

import Foundation

// MARK: - Internal Model
struct AppSource: Identifiable, Equatable {
    let name: String
    let identifier: String
    var apps: [SourceApp]
    var id: String { identifier }
}

enum SourceArtifact: String, Equatable {
    case apk, xapk, apkm, apks

    var downloadKind: Downloads.Job.Kind { self == .apk ? .apk : .bundle }

    static func resolve(_ declared: String?, url: String) -> SourceArtifact {
        let format = declared?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let format, let artifact = SourceArtifact(rawValue: format) { return artifact }
        if let ext = URL(string: url)?.pathExtension.lowercased(), let artifact = SourceArtifact(rawValue: ext) { return artifact }
        return .apk
    }
}

struct SourceApp: Identifiable, Equatable {
    let name: String
    let bundleIdentifier: String
    let version: String
    let downloadURL: String
    let iconURL: String
    let localizedDescription: String
    let categories: [String]
    let sizeBytes: Int64
    let sha256: String?
    let minimumSDK: Int?
    let targetSDK: Int?
    let architectures: [String]
    let artifact: SourceArtifact
    var id: String { bundleIdentifier }
}

// MARK: - F-Droid v1 Schema
private struct FDroidIndex: Codable {
    let repo: FDroidRepo
    let apps: [FDroidApp]
    let packages: [String: [FDroidPackage]]
}
private struct FDroidRepo: Codable { let name: String; let address: String }
private struct FDroidApp: Codable {
    let packageName: String
    let name: String?
    let summary: String?
    let description: String?
    let icon: String?
    let categories: [String]?
    let localized: [String: FDroidLocalized]?
}
private struct FDroidLocalized: Codable {
    let name: String?
    let summary: String?
    let description: String?
    let icon: String?
}
private struct FDroidPackage: Codable {
    let apkName: String
    let versionName: String
    let versionCode: Int64?
    let hash: String?
    let hashType: String?
    let size: Int64?
    let minSdkVersion: Int?
    let targetSdkVersion: Int?
    let nativecode: [String]?
}

// MARK: - Husk Simple Schema
private struct HuskSimpleSource: Codable {
    let name: String; let identifier: String; let apps: [SourceAppCodable]
}
private struct SourceAppCodable: Codable {
    let name, bundleIdentifier, version, downloadURL, iconURL, localizedDescription: String
    let categories: [String]?
    let sizeBytes: Int64?
    let sha256: String?
    let minimumSDK: Int?
    let targetSDK: Int?
    let architectures: [String]?
    let downloadFormat: String?
}

// MARK: - Manager
@MainActor
final class SourceManager: ObservableObject {
    static let shared = SourceManager()

    @Published var sources: [AppSource] = []
    @Published var loadingSources: Set<String> = Set<String>()
    @Published var fetchErrors: [String: String] = [String: String]()

    var isLoading: Bool { !loadingSources.isEmpty }

    @Published var sourceURLs: [String] = [
        "https://f-droid.org/repo/index-v1.json"
    ] {
        didSet {
            UserDefaults.standard.set(sourceURLs, forKey: "HuskSourceURLs")
        }
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "HuskSourceURLs"), !saved.isEmpty {
            sourceURLs = saved
        }
    }

    // Fetch everything (called on first appear / manual refresh)
    func fetchSources() async {
        for urlString in sourceURLs {
            if !sources.contains(where: { $0.identifier == urlString }) || loadingSources.isEmpty {
                await fetchSource(urlString: urlString)
            }
        }
    }

    // Add a new source and fetch ONLY that one
    func addSource(urlString: String) async {
        guard !sourceURLs.contains(urlString) else { return }
        sourceURLs.append(urlString)
        await fetchSource(urlString: urlString)
    }

    // Fetch a single source by URL
    func fetchSource(urlString: String) async {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            fetchErrors[urlString] = "Invalid repository URL"
            return
        }

        loadingSources.insert(urlString)
        fetchErrors.removeValue(forKey: urlString)

        defer { loadingSources.remove(urlString) }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                fetchErrors[urlString] = "Repository did not return an HTTP response."
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                fetchErrors[urlString] = "Repository returned HTTP \(http.statusCode)."
                return
            }

            // Try F-Droid v1 format
            if let fdroid = try? JSONDecoder().decode(FDroidIndex.self, from: data) {
                let baseURL = fdroid.repo.address.hasSuffix("/") ? String(fdroid.repo.address.dropLast()) : fdroid.repo.address
                var apps: [SourceApp] = []
                for fApp in fdroid.apps {
                    guard let pkgs = fdroid.packages[fApp.packageName],
                          let latest = pkgs.max(by: { ($0.versionCode ?? 0) < ($1.versionCode ?? 0) }) ?? pkgs.first else { continue }
                    let loc = fApp.localized?["en-US"] ?? fApp.localized?.values.first
                    let appName = fApp.name ?? loc?.name ?? fApp.packageName
                    let appSummary = fApp.summary ?? loc?.summary ?? fApp.description ?? loc?.description ?? ""
                    let appIcon = fApp.icon ?? loc?.icon
                    let iconURL = appIcon.map { "\(baseURL)/icons/\($0)" } ?? ""
                    let downloadURL = URL(string: latest.apkName, relativeTo: URL(string: baseURL + "/"))?.absoluteURL.absoluteString
                        ?? "\(baseURL)/\(latest.apkName)"
                    let sha256 = latest.hashType?.caseInsensitiveCompare("sha256") == .orderedSame ? latest.hash : nil

                    apps.append(SourceApp(
                        name: appName,
                        bundleIdentifier: fApp.packageName,
                        version: latest.versionName,
                        downloadURL: downloadURL,
                        iconURL: iconURL,
                        localizedDescription: appSummary,
                        categories: fApp.categories ?? [],
                        sizeBytes: latest.size ?? 0,
                        sha256: sha256,
                        minimumSDK: latest.minSdkVersion,
                        targetSDK: latest.targetSdkVersion,
                        architectures: latest.nativecode ?? [],
                        artifact: .apk
                    ))
                }
                apps.sort { $0.name.lowercased() < $1.name.lowercased() }
                let source = AppSource(name: fdroid.repo.name, identifier: urlString, apps: apps)
                upsert(source: source)
            }
            // Fallback: Husk simple format
            else if let simple = try? JSONDecoder().decode(HuskSimpleSource.self, from: data) {
                let apps = simple.apps.map {
                    SourceApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier,
                              version: $0.version, downloadURL: $0.downloadURL,
                              iconURL: $0.iconURL, localizedDescription: $0.localizedDescription,
                              categories: $0.categories ?? [], sizeBytes: $0.sizeBytes ?? 0,
                              sha256: $0.sha256, minimumSDK: $0.minimumSDK,
                              targetSDK: $0.targetSDK, architectures: $0.architectures ?? [],
                              artifact: SourceArtifact.resolve($0.downloadFormat, url: $0.downloadURL))
                }
                let source = AppSource(name: simple.name, identifier: urlString, apps: apps)
                upsert(source: source)
            } else {
                fetchErrors[urlString] = "Unrecognized source format"
                HuskLog.log("sources", "Unrecognized format at \(urlString)")
            }
        } catch {
            fetchErrors[urlString] = error.localizedDescription
            HuskLog.log("sources", "Failed to fetch \(urlString): \(error)")
        }
    }

    func removeSource(urlString: String) {
        sourceURLs.removeAll { $0 == urlString }
        sources.removeAll { $0.identifier == urlString }
        fetchErrors.removeValue(forKey: urlString)
    }

    private func upsert(source: AppSource) {
        if let idx = sources.firstIndex(where: { $0.identifier == source.identifier }) {
            sources[idx] = source
        } else {
            sources.append(source)
        }
    }

    // MARK: - Repository Download

    func download(app: SourceApp) {
        let safeVersion = app.version.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let filename = "\(app.bundleIdentifier)-\(safeVersion.isEmpty ? "latest" : safeVersion).\(app.artifact.rawValue)"
        Downloads.shared.addRepositoryArtifact(title: app.name, urlString: app.downloadURL, filename: filename,
                                               size: app.sizeBytes, sha256: app.sha256, kind: app.artifact.downloadKind)
    }
}

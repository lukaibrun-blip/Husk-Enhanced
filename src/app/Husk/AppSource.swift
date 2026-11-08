// SPDX-License-Identifier: GPL-2.0-or-later
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

struct SourceVersion: Identifiable, Equatable {
    let version: String
    let downloadURL: String
    let sizeBytes: Int64
    let sha256: String?
    let minimumSDK: Int?
    let targetSDK: Int?
    let architectures: [String]
    let artifact: SourceArtifact
    var id: String { downloadURL }
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
    let versions: [SourceVersion]
    var id: String { bundleIdentifier }

    var latestVersion: SourceVersion {
        versions.first ?? SourceVersion(version: version, downloadURL: downloadURL, sizeBytes: sizeBytes,
                                        sha256: sha256, minimumSDK: minimumSDK, targetSDK: targetSDK,
                                        architectures: architectures, artifact: artifact)
    }
    var versionOptions: [SourceVersion] { versions.isEmpty ? [latestVersion] : versions }
}

private enum RepositoryError: LocalizedError {
    case untrustedURL, invalidIndex, indexTooLarge

    var errorDescription: String? {
        switch self {
        case .untrustedURL: return "Repository and artifact URLs must use HTTPS and must not contain credentials."
        case .invalidIndex: return "The repository index contains invalid app metadata."
        case .indexTooLarge: return "The repository index exceeds Husk's 96 MB safety limit."
        }
    }
}

/// Streams a repository index with a hard byte cap rather than buffering an unbounded response in URLSession.data(from:).
private final class BoundedRepositoryLoader: NSObject, URLSessionDataDelegate {
    private let limit: Int
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(limit: Int) { self.limit = limit }

    func load(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 180
            configuration.urlCache = nil
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            task = session?.dataTask(with: url)
            task?.resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            completionHandler(nil)
            finish(.failure(RepositoryError.untrustedURL))
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(RepositoryError.invalidIndex))
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            finish(.failure(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Repository returned HTTP \(http.statusCode)."])))
            completionHandler(.cancel)
            return
        }
        if http.expectedContentLength > Int64(limit) {
            finish(.failure(RepositoryError.indexTooLarge))
            completionHandler(.cancel)
            return
        }
        self.response = http
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard chunk.count <= limit - data.count else {
            finish(.failure(RepositoryError.indexTooLarge))
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        guard let response else { finish(.failure(RepositoryError.invalidIndex)); return }
        finish(.success((data, response)))
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
    }
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
    let versions: [SourceVersionCodable]?
}
private struct SourceVersionCodable: Codable {
    let version: String
    let downloadURL: String
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

    private static let maxIndexBytes = 96 << 20

    private static func trustedURL(_ raw: String, relativeTo base: URL? = nil) -> URL? {
        guard let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func validPackageName(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+$", options: .regularExpression) != nil
    }

    private static func sourceVersion(version: String, downloadURL rawURL: String, sizeBytes: Int64?, sha256: String?,
                                      minimumSDK: Int?, targetSDK: Int?, architectures: [String]?, downloadFormat: String?,
                                      relativeTo baseURL: URL? = nil, requireAPKExtension: Bool = false) -> SourceVersion? {
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (sizeBytes ?? 0) >= 0, let url = trustedURL(rawURL, relativeTo: baseURL) else { return nil }
        let format = downloadFormat?.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let extensionName = url.pathExtension.lowercased()
        let declaredArtifact = format.flatMap { SourceArtifact(rawValue: $0) }
        let extensionArtifact = SourceArtifact(rawValue: extensionName)
        guard format == nil || format?.isEmpty == true || declaredArtifact != nil,
              extensionName.isEmpty || extensionArtifact != nil,
              declaredArtifact == nil || extensionArtifact == nil || declaredArtifact == extensionArtifact,
              !requireAPKExtension || extensionName == "apk" else { return nil }
        let checksum: String?
        if let sha256 {
            guard sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else { return nil }
            checksum = sha256.lowercased()
        } else {
            checksum = nil
        }
        return SourceVersion(version: version, downloadURL: url.absoluteString, sizeBytes: sizeBytes ?? 0,
                             sha256: checksum, minimumSDK: minimumSDK, targetSDK: targetSDK,
                             architectures: architectures ?? [], artifact: declaredArtifact ?? extensionArtifact ?? .apk)
    }

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

    // Add a new source and fetch ONLY that one.
    func addSource(urlString: String) async {
        guard let url = Self.trustedURL(urlString) else {
            fetchErrors[urlString] = RepositoryError.untrustedURL.localizedDescription
            return
        }
        let normalized = url.absoluteString
        guard !sourceURLs.contains(normalized) else { return }
        sourceURLs.append(normalized)
        await fetchSource(urlString: normalized)
    }

    // Fetch a single source by URL.
    func fetchSource(urlString: String) async {
        guard let url = Self.trustedURL(urlString) else {
            fetchErrors[urlString] = RepositoryError.untrustedURL.localizedDescription
            return
        }

        loadingSources.insert(urlString)
        fetchErrors.removeValue(forKey: urlString)
        defer { loadingSources.remove(urlString) }

        do {
            let (data, _) = try await BoundedRepositoryLoader(limit: Self.maxIndexBytes).load(url)
            var rejected = 0

            if let fdroid = try? JSONDecoder().decode(FDroidIndex.self, from: data) {
                guard !fdroid.repo.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      fdroid.apps.count <= 100_000,
                      let baseURL = Self.trustedURL(fdroid.repo.address),
                      let baseDirectory = URL(string: baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/") else {
                    throw RepositoryError.invalidIndex
                }
                var apps: [SourceApp] = []
                var seen = Set<String>()
                for fApp in fdroid.apps {
                    guard Self.validPackageName(fApp.packageName), seen.insert(fApp.packageName).inserted else { rejected += 1; continue }
                    guard let packages = fdroid.packages[fApp.packageName] else { continue }
                    let sortedPackages = packages.sorted { ($0.versionCode ?? 0) > ($1.versionCode ?? 0) }
                    var versions: [SourceVersion] = []
                    var seenVersionURLs = Set<String>()
                    for package in sortedPackages.prefix(100_000) {
                        let checksum = package.hashType?.caseInsensitiveCompare("sha256") == .orderedSame ? package.hash : nil
                        guard let version = Self.sourceVersion(version: package.versionName, downloadURL: package.apkName,
                                                               sizeBytes: package.size, sha256: checksum,
                                                               minimumSDK: package.minSdkVersion, targetSDK: package.targetSdkVersion,
                                                               architectures: package.nativecode, downloadFormat: nil,
                                                               relativeTo: baseDirectory, requireAPKExtension: true) else {
                            rejected += 1
                            continue
                        }
                        if seenVersionURLs.insert(version.downloadURL).inserted { versions.append(version) }
                    }
                    guard let latest = versions.first else { continue }
                    let localized = fApp.localized?["en-US"] ?? fApp.localized?.values.first
                    let appName = fApp.name ?? localized?.name ?? fApp.packageName
                    let appSummary = fApp.summary ?? localized?.summary ?? fApp.description ?? localized?.description ?? ""
                    let appIcon = fApp.icon ?? localized?.icon
                    let iconURL = appIcon.flatMap { Self.trustedURL("icons/\($0)", relativeTo: baseDirectory)?.absoluteString } ?? ""
                    apps.append(SourceApp(name: appName, bundleIdentifier: fApp.packageName, version: latest.version,
                                          downloadURL: latest.downloadURL, iconURL: iconURL,
                                          localizedDescription: appSummary, categories: fApp.categories ?? [],
                                          sizeBytes: latest.sizeBytes, sha256: latest.sha256, minimumSDK: latest.minimumSDK,
                                          targetSDK: latest.targetSDK, architectures: latest.architectures,
                                          artifact: latest.artifact, versions: versions))
                }
                apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                upsert(source: AppSource(name: fdroid.repo.name, identifier: urlString, apps: apps))
            } else if let simple = try? JSONDecoder().decode(HuskSimpleSource.self, from: data) {
                guard !simple.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      simple.apps.count <= 100_000 else { throw RepositoryError.invalidIndex }
                var apps: [SourceApp] = []
                var seen = Set<String>()
                for entry in simple.apps {
                    guard Self.validPackageName(entry.bundleIdentifier), seen.insert(entry.bundleIdentifier).inserted,
                          !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          entry.iconURL.isEmpty || Self.trustedURL(entry.iconURL) != nil,
                          let latest = Self.sourceVersion(version: entry.version, downloadURL: entry.downloadURL,
                                                         sizeBytes: entry.sizeBytes, sha256: entry.sha256,
                                                         minimumSDK: entry.minimumSDK, targetSDK: entry.targetSDK,
                                                         architectures: entry.architectures, downloadFormat: entry.downloadFormat) else {
                        rejected += 1
                        continue
                    }
                    var versions = [latest]
                    var seenVersionURLs = Set([latest.downloadURL])
                    for rawVersion in (entry.versions ?? []).prefix(1_000) {
                        guard let version = Self.sourceVersion(version: rawVersion.version, downloadURL: rawVersion.downloadURL,
                                                               sizeBytes: rawVersion.sizeBytes, sha256: rawVersion.sha256,
                                                               minimumSDK: rawVersion.minimumSDK, targetSDK: rawVersion.targetSDK,
                                                               architectures: rawVersion.architectures, downloadFormat: rawVersion.downloadFormat) else {
                            rejected += 1
                            continue
                        }
                        if seenVersionURLs.insert(version.downloadURL).inserted { versions.append(version) }
                    }
                    apps.append(SourceApp(name: entry.name, bundleIdentifier: entry.bundleIdentifier, version: latest.version,
                                          downloadURL: latest.downloadURL, iconURL: entry.iconURL,
                                          localizedDescription: entry.localizedDescription, categories: entry.categories ?? [],
                                          sizeBytes: latest.sizeBytes, sha256: latest.sha256,
                                          minimumSDK: latest.minimumSDK, targetSDK: latest.targetSDK,
                                          architectures: latest.architectures, artifact: latest.artifact, versions: versions))
                }
                upsert(source: AppSource(name: simple.name, identifier: urlString, apps: apps))
            } else {
                throw RepositoryError.invalidIndex
            }

            if rejected > 0 {
                fetchErrors[urlString] = "Skipped \(rejected) entries with duplicate IDs or invalid metadata."
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

    func download(app: SourceApp, version: SourceVersion? = nil) {
        let selected = version ?? app.latestVersion
        let safeVersion = selected.version.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let filename = "\(app.bundleIdentifier)-\(safeVersion.isEmpty ? "latest" : safeVersion).\(selected.artifact.rawValue)"
        Downloads.shared.addRepositoryArtifact(title: "\(app.name) \(selected.version)", urlString: selected.downloadURL, filename: filename,
                                               size: selected.sizeBytes, sha256: selected.sha256, kind: selected.artifact.downloadKind)
    }
}

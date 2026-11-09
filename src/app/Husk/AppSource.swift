// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation

struct EspacioAPKCategory: Decodable, Equatable, Identifiable {
    let id: Int
    let name: String
    let slug: String
    let count: Int?
}

struct EspacioAPKRendered: Decodable, Equatable {
    let rendered: String
}

struct EspacioAPKPost: Decodable, Equatable, Identifiable {
    let id: Int
    let date: String?
    let slug: String?
    let link: String?
    let title: EspacioAPKRendered?
    let excerpt: EspacioAPKRendered?
    let content: EspacioAPKRendered?
    let categories: [Int]?

    var titleText: String { title.map { EspacioAPKHTML.plainText($0.rendered) } ?? "Untitled listing" }
    var summaryText: String { excerpt.map { EspacioAPKHTML.plainText($0.rendered) } ?? "" }
    var contentText: String { content.map { EspacioAPKHTML.plainText($0.rendered) } ?? "" }
    var articleURL: URL? { EspacioAPKPolicy.articleURL(link) }
    var claimsModifiedContent: Bool { EspacioAPKPolicy.claimsModifiedContent("\(titleText) \(summaryText) \(contentText)") }
}

enum EspacioAPKPolicy {
    static let host = "espacioapk.com"

    static func siteURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host,
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }

    static func catalogURL(_ raw: String?) -> URL? {
        guard let url = siteURL(raw),
              url.path == "/wp-json/wp/v2/posts" || url.path == "/wp-json/wp/v2/categories" else { return nil }
        return url
    }

    static func articleURL(_ raw: String?) -> URL? {
        guard let url = siteURL(raw), url.query == nil, url.fragment == nil else { return nil }
        let components = url.path.split(separator: "/").map { $0.lowercased() }
        guard !components.isEmpty, !url.path.lowercased().hasPrefix("/wp-json/"),
              !components.contains("next"), !components.contains("download") else { return nil }
        return url
    }

    static func isAllowed(_ post: EspacioAPKPost, categoryNames: [String]) -> Bool {
        let listing = [post.titleText, post.summaryText, post.contentText, categoryNames.joined(separator: " ")]
            .joined(separator: " ")
        return !containsRestrictedGamblingContent(listing)
    }

    static func containsRestrictedGamblingContent(_ text: String) -> Bool {
        let normalized = normalize(text)
        return gamblingPatterns.contains { normalized.range(of: $0, options: .regularExpression) != nil }
    }

    static func claimsModifiedContent(_ text: String) -> Bool {
        let normalized = normalize(text)
        return modifiedPatterns.contains { normalized.range(of: $0, options: .regularExpression) != nil }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static let gamblingPatterns = [
        #"\bcasino(s)?\b"#, #"\bgambling\b"#, #"\bbet(ting)?\b"#, #"\bsportsbook\b"#,
        #"\bbookmaker(s)?\b"#, #"\b(apuesta(s)?|aposta(s)?|apostar|apostador|aposte)\b"#,
        #"\b(juego(s)? de azar|jogo(s)? de azar|casa de apuestas)\b"#,
        #"\btragamonedas\b"#, #"\btragaperras\b"#, #"\bslots?\b"#,
        #"\broulette\b"#, #"\bruleta\b"#, #"\bpoker\b"#,
        #"\b1win\b"#, #"\b888starz\b"#, #"\b888casino\b"#, #"\bbet365\b"#,
        #"\bbetano\b"#, #"\bparimatch\b"#, #"\bmostbet\b"#, #"\bstake\.com\b"#
    ]

    private static let modifiedPatterns = [
        #"\bmod(s|ded)?\b"#, #"\bmodified\b"#, #"\bmodificado(s)?\b"#,
        #"\bhack(ed|s)?\b"#, #"\bunlocked\b"#, #"\bpremium apk\b"#,
        #"\bcheat(s)?\b"#, #"\bmod menu\b"#
    ]
}

enum EspacioAPKHTML {
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        let entities = [
            "&nbsp;": " ", "&#160;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#039;": "'", "&apos;": "'", "&#8217;": "'",
            "&#8216;": "'", "&#8211;": "-", "&#8212;": "-", "&hellip;": "…"
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

private enum EspacioAPKError: LocalizedError {
    case invalidEndpoint, invalidResponse, responseTooLarge, httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "EspacioAPK returned an invalid or off-site link."
        case .invalidResponse: return "EspacioAPK returned an unexpected response."
        case .responseTooLarge: return "The EspacioAPK response exceeded the 8 MB safety limit."
        case .httpStatus(let status): return "EspacioAPK returned HTTP \(status)."
        }
    }
}

private final class EspacioAPKResponseLoader: NSObject, URLSessionDataDelegate {
    private let limit: Int
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(limit: Int) { self.limit = limit }

    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.urlCache = nil
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            task = session?.dataTask(with: request)
            task?.resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard EspacioAPKPolicy.catalogURL(request.url?.absoluteString) != nil else {
            completionHandler(nil)
            finish(.failure(EspacioAPKError.invalidEndpoint))
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              EspacioAPKPolicy.catalogURL(response.url?.absoluteString) != nil else {
            finish(.failure(EspacioAPKError.invalidResponse))
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            finish(.failure(EspacioAPKError.httpStatus(http.statusCode)))
            completionHandler(.cancel)
            return
        }
        if http.expectedContentLength > Int64(limit) {
            finish(.failure(EspacioAPKError.responseTooLarge))
            completionHandler(.cancel)
            return
        }
        self.response = http
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard chunk.count <= limit - data.count else {
            finish(.failure(EspacioAPKError.responseTooLarge))
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        guard let response else { finish(.failure(EspacioAPKError.invalidResponse)); return }
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

@MainActor
final class EspacioAPKCatalog: ObservableObject {
    struct Page {
        let posts: [EspacioAPKPost]
        let totalPages: Int
    }

    @Published private(set) var categories: [EspacioAPKCategory] = []
    @Published private(set) var categoriesLoaded = false
    @Published private(set) var posts: [EspacioAPKPost] = []
    @Published private(set) var isLoadingCategories = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var categoriesError: String?
    @Published private(set) var error: String?
    @Published private(set) var currentPage = 0
    @Published private(set) var totalPages = 1

    private var generation = 0
    private static let responseLimit = 8 * 1024 * 1024

    var hasMorePages: Bool { currentPage < totalPages }

    func loadCategories() async {
        guard !isLoadingCategories else { return }
        isLoadingCategories = true
        categoriesError = nil
        defer { isLoadingCategories = false }
        do {
            categories = try await Self.get([EspacioAPKCategory].self, resource: "categories", query: [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "hide_empty", value: "true")
            ]).filter { !EspacioAPKPolicy.containsRestrictedGamblingContent($0.name) }
            categoriesLoaded = true
        } catch {
            categoriesError = error.localizedDescription
            categoriesLoaded = false
        }
    }

    func refresh(search: String, category: Int?) async {
        generation += 1
        let requestGeneration = generation
        isLoadingMore = false
        posts = []
        currentPage = 0
        totalPages = 1
        error = nil
        isLoading = true
        defer { if generation == requestGeneration { isLoading = false } }
        do {
            let result = try await Self.fetchPosts(search: search, category: category, page: 1)
            guard generation == requestGeneration else { return }
            posts = result.posts
            currentPage = 1
            totalPages = result.totalPages
        } catch {
            guard generation == requestGeneration else { return }
            self.error = error.localizedDescription
        }
    }

    func loadNextPage(search: String, category: Int?) async {
        guard !isLoading, !isLoadingMore, hasMorePages else { return }
        let requestGeneration = generation
        let nextPage = currentPage + 1
        isLoadingMore = true
        defer { if generation == requestGeneration { isLoadingMore = false } }
        do {
            let result = try await Self.fetchPosts(search: search, category: category, page: nextPage)
            guard generation == requestGeneration else { return }
            let knownIDs = Set(posts.map(\.id))
            posts.append(contentsOf: result.posts.filter { !knownIDs.contains($0.id) })
            currentPage = nextPage
            totalPages = result.totalPages
            error = nil
        } catch {
            guard generation == requestGeneration else { return }
            self.error = error.localizedDescription
        }
    }

    private static func fetchPosts(search: String, category: Int?, page: Int) async throws -> Page {
        var query = [
            URLQueryItem(name: "per_page", value: "20"),
            URLQueryItem(name: "page", value: String(page))
        ]
        let trimmedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty { query.append(URLQueryItem(name: "search", value: trimmedSearch)) }
        if let category { query.append(URLQueryItem(name: "categories", value: String(category))) }
        let (posts, response) = try await get([EspacioAPKPost].self, resource: "posts", query: query)
        let pages = Int(response.value(forHTTPHeaderField: "X-WP-TotalPages") ?? "1") ?? 1
        return Page(posts: posts, totalPages: max(1, pages))
    }

    private static func get<T: Decodable>(_ type: T.Type, resource: String, query: [URLQueryItem]) async throws -> T {
        guard resource == "posts" || resource == "categories" else { throw EspacioAPKError.invalidEndpoint }
        var components = URLComponents()
        components.scheme = "https"
        components.host = EspacioAPKPolicy.host
        components.path = "/wp-json/wp/v2/\(resource)"
        components.queryItems = query
        guard let url = components.url, EspacioAPKPolicy.catalogURL(url.absoluteString) != nil else {
            throw EspacioAPKError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, _) = try await EspacioAPKResponseLoader(limit: responseLimit).load(request)
        return try JSONDecoder().decode(type, from: data)
    }
}

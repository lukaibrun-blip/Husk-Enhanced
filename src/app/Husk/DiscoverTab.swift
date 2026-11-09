// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Apps from the repositories you add, saved into Husk's translation-layer library.
struct DiscoverView: View {
    var navigationTitle: String = "Discover"

    @ObservedObject private var manager = SourceManager.shared
    @ObservedObject private var host = AndroidHost.shared
    @ObservedObject private var downloads = Downloads.shared
    @ObservedObject private var library = TranslationLayerStore.shared

    @State private var selectedApp: SourceApp?
    @State private var selectedCategory: String?
    @State private var showingSources = false
    @State private var showingAddSource = false
    @State private var newSourceURL = ""
    @State private var searchText = ""
    @State private var debouncedSearchText = ""

    var body: some View {
        Group {
            if manager.isLoading && manager.sources.isEmpty {
                ProgressView("Fetching Repositories…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if manager.sources.isEmpty {
                EmptyState(title: "No Repositories",
                           message: "Add a source to start discovering apps.",
                           systemImage: "tray",
                           actionTitle: "Add Source",
                           action: { showingAddSource = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .background(Theme.backdrop)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search \(totalAppCount) apps")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !categories.isEmpty {
                    Menu {
                        Button("All Categories") { selectedCategory = nil }
                        ForEach(categories, id: \.self) { category in
                            Button(category) { selectedCategory = category }
                        }
                    } label: {
                        Image(systemName: selectedCategory == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                            .accessibilityLabel(selectedCategory ?? "Filter categories")
                    }
                }
                Button { Task { await manager.fetchSources() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Menu {
                    Button { showingAddSource = true } label: {
                        Label("Add Source", systemImage: "plus")
                    }
                    Button { showingSources = true } label: {
                        Label("Manage Repositories", systemImage: "list.bullet")
                    }
                } label: { Label("Repositories", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showingSources) { sourcesSheet }
        .sheet(isPresented: $showingAddSource) { addSourceSheet }
        .sheet(item: $selectedApp) { SourceAppDetailSheet(app: $0) }
        .onAppear {
            if manager.sources.isEmpty && !manager.isLoading {
                Task { await manager.fetchSources() }
            }
        }
        .task(id: searchText) {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                debouncedSearchText = searchText
            } catch {}
        }
    }

    private var list: some View {
        HuskPageList {
            ForEach(manager.sources) { source in
                let filtered = filteredApps(for: source)
                if !filtered.isEmpty {
                    sourceSection(source, apps: filtered)
                }
            }
            if manager.sources.allSatisfy({ filteredApps(for: $0).isEmpty }), manager.fetchErrors.isEmpty {
                Section {
                    Text("No apps match these filters.").foregroundStyle(.secondary)
                }
            }
            if !manager.fetchErrors.isEmpty {
                Section {
                    ForEach(manager.fetchErrors.keys.sorted(), id: \.self) { url in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url).font(.footnote).lineLimit(1)
                                Text(manager.fetchErrors[url] ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    }
                } header: { Text("Could Not Load") }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var totalAppCount: Int {
        manager.sources.reduce(0) { $0 + $1.apps.count }
    }

    private var categories: [String] {
        Array(Set(manager.sources.flatMap { $0.apps.flatMap(\.categories) })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Helpers

    private func filteredApps(for source: AppSource) -> [SourceApp] {
        source.apps.filter { app in
            let matchesCategory = selectedCategory == nil || app.categories.contains(selectedCategory!)
            guard matchesCategory, !debouncedSearchText.isEmpty else { return matchesCategory }
            let query = debouncedSearchText.lowercased()
            return app.name.lowercased().contains(query) ||
                app.bundleIdentifier.lowercased().contains(query) ||
                app.localizedDescription.lowercased().contains(query) ||
                app.categories.contains { $0.lowercased().contains(query) }
        }
    }

    private func sourceSection(_ source: AppSource, apps: [SourceApp]) -> some View {
        let displayApps = debouncedSearchText.isEmpty ? Array(apps.prefix(50)) : apps
        return Section {
            ForEach(displayApps) { app in appRow(app) }
        } header: {
            Text(source.name)
        } footer: {
            if debouncedSearchText.isEmpty && apps.count > 50 {
                Text("Search to see \(apps.count - 50) more apps.")
            }
        }
    }

    private func appRow(_ app: SourceApp) -> some View {
        let job = downloads.jobs.first { $0.source == app.downloadURL && $0.kind == app.artifact.downloadKind }
        let inLibrary = library.apps.contains { $0.packageName == app.bundleIdentifier }
        let isInstalled = host.packages.contains { $0.id == app.bundleIdentifier }
        return HStack(spacing: 14) {
            Button { selectedApp = app } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: app.iconURL)) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fit)
                        } else if phase.error != nil {
                            Image(systemName: "app.dashed").font(.title).foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                        Text(app.localizedDescription)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text([app.version, app.sizeBytes > 0 ? Downloads.bytes(app.sizeBytes) : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isInstalled {
                Button("Open") {
                    let intent = "am start -n \(app.bundleIdentifier)/\(app.bundleIdentifier).MainActivity"
                    _ = try? GuestBridge.shared.shell(intent, timeout: 5)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            } else if let job, job.complete, job.ingestion == .adding {
                Label("Adding to library…", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            } else if let job, job.complete, job.ingestion == .added {
                Label("Added", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.green)
            } else if let job, job.complete, job.ingestion == .failed {
                Label("Ingestion failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
            } else if let job, job.complete, job.ingestion == .interrupted {
                Label("Check library", systemImage: "questionmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
            } else if let job, job.complete {
                Label("Downloaded", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            } else if let job {
                Button {
                    if job.paused || job.failed { downloads.resume(job.id) } else { downloads.pause(job.id) }
                } label: {
                    ZStack {
                        Circle().stroke(Color(uiColor: .tertiarySystemFill), lineWidth: 3)
                        Circle().trim(from: 0, to: job.total > 0 ? min(1, Double(job.received) / Double(job.total)) : 0.05)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: job.paused || job.failed ? "arrow.clockwise" : "pause.fill")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(job.failed ? "Retry download" : job.paused ? "Resume download" : "Pause download")
            } else if inLibrary {
                Label("Added", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.green)
            } else {
                Button("Get") { manager.download(app: app) }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
    }

    // MARK: - Add Source Sheet

    private var addSourceSheet: some View {
        NavigationStack {
            HuskForm {
                Section {
                    TextField("https://f-droid.org/repo/index-v1.json", text: $newSourceURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("Source URL")
                } footer: {
                    Text("Paste an F-Droid-compatible index or a Husk Simple catalog. Only add repositories authorized to distribute the apps they list.")
                }

                Section("Presets") {
                    ForEach([
                        ("F-Droid", "https://f-droid.org/repo/index-v1.json"),
                        ("IzzyOnDroid", "https://apt.izzysoft.de/fdroid/repo/index-v1.json"),
                        ("Guardian Project", "https://guardianproject.info/fdroid/repo/index-v1.json"),
                    ], id: \.0) { name, url in
                        Button { newSourceURL = url } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name).foregroundStyle(.primary)
                                    Text(url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if newSourceURL == url {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { newSourceURL = ""; showingAddSource = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        let url = newSourceURL
                        newSourceURL = ""
                        showingAddSource = false
                        guard !url.isEmpty, URL(string: url) != nil else { return }
                        Task { await manager.addSource(urlString: url) }
                    }
                    .disabled(newSourceURL.isEmpty)
                    .huskBold()
                }
            }
        }
    }

    // MARK: - Manage Sources Sheet

    private var sourcesSheet: some View {
        NavigationStack {
            HuskPageList {
                Section {
                    ForEach(manager.sourceURLs, id: \.self) { url in
                        VStack(alignment: .leading, spacing: 2) {
                            if let source = manager.sources.first(where: { $0.identifier == url }) {
                                Text(source.name).font(.body.weight(.medium))
                                Text("\(source.apps.count) apps").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { offsets in
                        let urls = offsets.map { manager.sourceURLs[$0] }
                        for url in urls { manager.removeSource(urlString: url) }
                    }
                } header: { Text("Active Repositories") }
            }
            .navigationTitle("Repositories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { showingSources = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSources = false; showingAddSource = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }
}



private struct SourceAppDetailSheet: View {
    let app: SourceApp
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sources = SourceManager.shared
    @ObservedObject private var downloads = Downloads.shared
    @ObservedObject private var library = TranslationLayerStore.shared
    @State private var selectedVersionURL: String?

    init(app: SourceApp) {
        self.app = app
        _selectedVersionURL = State(initialValue: app.latestVersion.downloadURL)
    }

    private var selectedVersion: SourceVersion {
        app.versionOptions.first { $0.id == selectedVersionURL } ?? app.latestVersion
    }
    private var job: Downloads.Job? {
        downloads.jobs.first { $0.source == selectedVersion.downloadURL && $0.kind == selectedVersion.artifact.downloadKind }
    }
    private var inLibrary: Bool { library.apps.contains { $0.packageName == app.bundleIdentifier } }
    private var repository: String {
        sources.sources.first { source in source.apps.contains { $0.downloadURL == app.downloadURL } }?.name ?? "Repository"
    }
    private var compatibility: String {
        let sdk = selectedVersion.minimumSDK.map { "Android API \($0)+" } ?? "minimum Android version not declared"
        let abi = selectedVersion.architectures.isEmpty ? "native ABI not declared" : selectedVersion.architectures.joined(separator: ", ")
        return "\(sdk) · \(abi)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        AsyncImage(url: URL(string: app.iconURL)) { phase in
                            if let image = phase.image { image.resizable().scaledToFit() }
                            else { Image(systemName: "app.dashed").font(.largeTitle).foregroundStyle(.secondary) }
                        }
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.title2.weight(.bold))
                            Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }

                    if !app.localizedDescription.isEmpty {
                        Text(app.localizedDescription).font(.body).fixedSize(horizontal: false, vertical: true)
                    }

                    if app.versionOptions.count > 1 {
                        Picker("Available version", selection: $selectedVersionURL) {
                            ForEach(app.versionOptions) { version in
                                Text(version.version).tag(Optional(version.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    VStack(spacing: 10) {
                        metadata("Repository", repository)
                        metadata("Version", selectedVersion.version)
                        if selectedVersion.sizeBytes > 0 { metadata("Download size", Downloads.bytes(selectedVersion.sizeBytes)) }
                        metadata("Artifact", selectedVersion.artifact.rawValue.uppercased())
                        metadata("Declared compatibility", compatibility)
                        if let target = selectedVersion.targetSDK { metadata("Target Android API", String(target)) }
                        if !app.categories.isEmpty { metadata("Categories", app.categories.joined(separator: ", ")) }
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if selectedVersion.sha256 != nil {
                        Label("The repository publishes a SHA-256 checksum; Husk verifies it before adding the download to your library.", systemImage: "checkmark.shield.fill")
                            .font(.footnote).foregroundStyle(.green)
                    } else {
                        Label("This repository does not publish a SHA-256 checksum for this download.", systemImage: "exclamationmark.shield.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Text("Compatibility is limited to the Android version and native ABIs declared by the repository. Husk cannot confirm that this app runs on this device until it is tried.")
                        .font(.footnote).foregroundStyle(.secondary)

                    if inLibrary {
                        Label("Already in Husk’s library; downloading another version adds it as an update.", systemImage: "checkmark.circle.fill")
                            .font(.footnote).foregroundStyle(.green)
                    }
                    if let problem = downloads.problem {
                        Text(problem).font(.footnote).foregroundStyle(.orange)
                    }

                    if let job, job.complete, job.ingestion == .adding {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView()
                            Label("Download complete; adding to the library…", systemImage: "arrow.down.circle.fill")
                                .font(.headline).foregroundStyle(.secondary)
                        }
                    } else if let job, job.complete, job.ingestion == .added {
                        Label("Added to Husk’s library", systemImage: "checkmark.circle.fill")
                            .font(.headline).foregroundStyle(.green)
                    } else if let job, job.complete, job.ingestion == .failed {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Library ingestion failed", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline).foregroundStyle(.orange)
                            Text(job.ingestionError ?? "Husk could not add this download to the library.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Retry Ingestion") { downloads.retryIngestion(job.id) }
                                .buttonStyle(.bordered)
                        }
                    } else if let job, job.complete, job.ingestion == .interrupted {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Ingestion interrupted", systemImage: "questionmark.circle.fill")
                                .font(.headline).foregroundStyle(.orange)
                            Text(job.ingestionError ?? "Check the library to see whether this download was added.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Retry Ingestion") { downloads.retryIngestion(job.id) }
                                .buttonStyle(.bordered)
                        }
                    } else if let job, job.complete {
                        Label("Download complete; awaiting library status", systemImage: "arrow.down.circle.fill")
                            .font(.headline).foregroundStyle(.secondary)
                    } else if let job {
                        VStack(alignment: .leading, spacing: 10) {
                            if job.total > 0 { ProgressView(value: min(1, Double(job.received) / Double(job.total))) }
                            else { ProgressView() }
                            HStack {
                                Text(job.failed ? (job.files.first?.error ?? "Download failed") : job.paused ? "Paused" : "Downloading")
                                    .font(.caption).foregroundStyle(job.failed ? Color.orange : Color.secondary)
                                Spacer()
                                Button(job.failed ? "Retry" : job.paused ? "Resume" : "Pause") {
                                    if job.paused || job.failed { downloads.resume(job.id) } else { downloads.pause(job.id) }
                                }
                                Button("Cancel", role: .destructive) { downloads.remove(job.id) }
                            }
                        }
                    } else {
                        Button { sources.download(app: app, version: selectedVersion) } label: {
                            Label("Download \(selectedVersion.artifact.rawValue.uppercased())", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
            }
            .navigationTitle("App Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .background(Theme.backdrop)
        }
    }

    private func metadata(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.footnote)
    }
}

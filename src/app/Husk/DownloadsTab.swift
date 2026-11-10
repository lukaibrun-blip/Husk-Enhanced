// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Downloads from a link, and what has an update.
struct DownloadsTab: View {
    @ObservedObject private var downloads = Downloads.shared
    @ObservedObject private var store = PlayStoreManager.shared
    @ObservedObject private var updates = AppUpdates.shared
    @ObservedObject private var guest = GuestImage.shared
    @State private var adding = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HuskPageList {
                updatesSection
                Section {
                    if downloads.jobs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No downloads").font(.headline)
                            Text("Add a link to an APK or a file, or the address a computer gives you when it shares a folder.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    ForEach(store.downloadProgress.keys.sorted(), id: \.self) { pkg in
                        HStack(spacing: 10) {
                            Image(systemName: "bag.fill").foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(store.downloadTitles[pkg] ?? pkg).font(.headline).lineLimit(1)
                                ProgressView(value: store.downloadProgress[pkg] ?? 0)
                                Text("From the Store").font(.caption).foregroundStyle(.secondary)
                            }
                            Button(role: .destructive) { store.cancelDownload(pkg) } label: {
                                Image(systemName: "xmark.circle.fill").font(.title2)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Cancel Download")
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(downloads.jobs) { job in
                        DownloadRow(job: job, speed: downloads.speed)
                            .swipeActions {
                                Button(role: .destructive) { downloads.remove(job.id) } label: { Label("Remove", systemImage: "trash") }
                            }
                    }
                } header: {
                    HStack {
                        Text("Downloads")
                        Spacer()
                        if downloads.jobs.contains(where: { $0.complete && $0.ingestion != .adding }) {
                            Button("Clear Finished") { downloads.clearFinished() }.font(.caption).textCase(nil)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if downloads.liveActivitiesOff {
                            Text("Live Activities are off for Husk, so downloads don't show on the Lock Screen or in the Dynamic Island. Turn them on in Settings › Husk › Live Activities.")
                                .foregroundStyle(.orange)
                        }
                        if let free = Downloads.freeSpace() { Text("\(Downloads.bytes(free)) free on this device.") }
                    }
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $adding) { AddDownloadSheet() }
        }
    }

    @ViewBuilder private var updatesSection: some View {
        Section("Updates") {
            if let release = updates.available {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Husk \(release.version)", systemImage: "arrow.down.app.fill")
                        Spacer()
                        Button("Download") { UIApplication.shared.open(release.updateURL) }.buttonStyle(.bordered)
                    }
                    Text(release.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            if guest.update.isSomething {
                HStack {
                    Label(guest.update.title, systemImage: "shippingbox.fill")
                    Spacer()
                    Button("Download") { guest.applyUpdate() }.buttonStyle(.bordered)
                }
            }
            if let error = updates.errorMessage {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if updates.available == nil && !guest.update.isSomething {
                Label(updates.checking ? "Checking for updates…" : updates.statusMessage ?? "App updates are checked periodically",
                      systemImage: updates.checking ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct DownloadRow: View {
    let job: Downloads.Job
    let speed: Double

    private var fraction: Double { job.total > 0 ? min(1, Double(job.received) / Double(job.total)) : 0 }

    private var status: String {
        if job.complete {
            guard job.isLibraryArtifact else { return "In Shared Storage" }
            switch job.ingestion {
            case .adding: return "Adding to the library…"
            case .added: return "Added to the library"
            case .failed: return "Ingestion failed: \(job.ingestionError ?? "Unknown error")"
            case .interrupted: return job.ingestionError ?? "Ingestion interrupted; check the library."
            case nil: return "Downloaded"
            }
        }
        if job.paused { return "Paused · \(Downloads.bytes(job.received)) of \(Downloads.bytes(job.total))" }
        if let err = job.files.first(where: { $0.error != nil })?.error { return "Stopped: \(err)" }
        var s = "\(Downloads.bytes(job.received)) of \(Downloads.bytes(job.total))"
        if job.files.count > 1 { s += " · \(job.filesDone)/\(job.files.count) files" }
        if speed > 1 {
            s += " · \(Downloads.bytes(Int64(speed)))/s"
            let left = Double(job.total - job.received) / speed
            if left.isFinite, left > 0 {
                let f = DateComponentsFormatter(); f.allowedUnits = left > 3600 ? [.hour, .minute] : [.minute, .second]; f.unitsStyle = .abbreviated
                if let t = f.string(from: left) { s += " · \(t) left" }
            }
        }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: job.kind == .folder ? "folder.fill" : job.kind == .apk || job.kind == .bundle ? "app.badge.fill" : "doc.fill")
                    .foregroundStyle(job.complete && (!job.isLibraryArtifact || job.ingestion == .added) ? Color.green : Color.accentColor)
                Text(job.title).font(.headline).lineLimit(1)
                Spacer()
                if !job.complete {
                    Button {
                        if job.paused || job.failed { Downloads.shared.resume(job.id) } else { Downloads.shared.pause(job.id) }
                    } label: {
                        Image(systemName: job.paused || job.failed ? "arrow.clockwise.circle.fill" : "pause.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    Button(role: .destructive) { Downloads.shared.remove(job.id) } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel Download")
                } else if job.ingestion == .failed || job.ingestion == .interrupted {
                    Button("Retry") { Downloads.shared.retryIngestion(job.id) }
                        .buttonStyle(.borderless)
                }
            }
            if !job.complete { ProgressView(value: fraction) }
            else if job.ingestion == .adding { ProgressView() }
            Text(status).font(.caption)
                .foregroundStyle(job.failed || job.ingestion == .failed || job.ingestion == .interrupted ? Color.orange : Color.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

private struct AddDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloads = Downloads.shared
    @State private var link = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            HuskForm {
                Section {
                    TextField("https://… or http://192.168.1.20:8642/", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if let problem = downloads.problem { Text(problem).foregroundStyle(.orange) }
                }
                Section {
                    Text("An APK is added to your library when it finishes. Anything else goes into the Shared Storage folder, which games see as their phone storage.")
                    Text("To send a whole folder from a computer on the same Wi‑Fi, run this on it and enter the address it shows:")
                    Text("python3 serve-folder.py <folder>")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Text("serve-folder.py is in Husk's repository, under tools. The folder's contents land at the top of Shared Storage, so serve the folder that holds what a game expects there.")
                } header: {
                    Text("How it works")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Add Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Download") {
                            working = true
                            Task {
                                await downloads.add(link: link)
                                working = false
                                if downloads.problem == nil { dismiss() }
                            }
                        }
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear { downloads.problem = nil }
        }
    }
}

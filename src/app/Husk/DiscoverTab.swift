// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// A read-only browser for EspacioAPK's public WordPress listings.
/// APK links are deliberately not followed: the catalog does not publish verifiable APK hashes or signer identities.
struct EspacioAPKView: View {
    var navigationTitle = "APK Store"

    @StateObject private var catalog = EspacioAPKCatalog()
    @State private var selectedPost: EspacioAPKPost?
    @State private var selectedCategory: Int?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""

    private var categoryNames: [Int: String] {
        Dictionary(uniqueKeysWithValues: catalog.categories.map { ($0.id, $0.name) })
    }

    private var visiblePosts: [EspacioAPKPost] {
        guard catalog.categoriesLoaded else { return [] }
        return catalog.posts.filter { post in
            let names = (post.categories ?? []).compactMap { categoryNames[$0] }
            return EspacioAPKPolicy.isAllowed(post, categoryNames: names)
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 7) {
                    Label("EspacioAPK listings only", systemImage: "exclamationmark.shield.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("Search and browse article metadata. APK files, versions, SHA-256 hashes, and signing certificates are not exposed in a stable, verifiable catalog feed, so downloads and installation are disabled here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }

            if let categoriesError = catalog.categoriesError {
                Section("Categories unavailable") {
                    Text(categoriesError).font(.footnote).foregroundStyle(.secondary)
                    Button("Retry Categories") {
                        Task { await catalog.loadCategories() }
                    }
                    .disabled(catalog.isLoadingCategories)
                }
            }

            if catalog.isLoading && catalog.posts.isEmpty {
                Section { ProgressView("Loading EspacioAPK listings…") }
            } else if let error = catalog.error, catalog.posts.isEmpty {
                Section("Could Not Load") {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("Try Again") { refresh() }
                }
            } else if !catalog.categoriesLoaded {
                Section {
                    Text("Listings are hidden until EspacioAPK categories can be checked.")
                        .foregroundStyle(.secondary)
                }
            } else if visiblePosts.isEmpty {
                Section {
                    Text(catalog.posts.isEmpty ? "No listings match this search." : "No listings match these filters. Restricted gambling content is hidden.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Listings") {
                    ForEach(visiblePosts) { post in
                        Button { selectedPost = post } label: { row(post) }
                            .buttonStyle(.plain)
                    }
                }

                if catalog.hasMorePages {
                    Section {
                        if catalog.isLoadingMore {
                            ProgressView("Loading more listings…")
                        } else {
                            Button("Load More") { loadMore() }
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }

            if let error = catalog.error, !catalog.posts.isEmpty {
                Section("Could Not Load More") {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("Try Again") { loadMore() }
                }
            }
        }
        .listStyle(.insetGrouped)
        .background(Theme.backdrop)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search EspacioAPK listings")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !catalog.categories.isEmpty {
                    Menu {
                        Button("All Categories") { selectedCategory = nil }
                        ForEach(catalog.categories) { category in
                            Button(category.name) { selectedCategory = category.id }
                        }
                    } label: {
                        Image(systemName: selectedCategory == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                            .accessibilityLabel(selectedCategory.flatMap { categoryNames[$0] } ?? "Filter categories")
                    }
                }
                Button { refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(catalog.isLoading)
            }
        }
        .refreshable { await catalog.refresh(search: debouncedSearchText, category: selectedCategory) }
        .sheet(item: $selectedPost) { post in
            EspacioAPKPostDetail(post: post, categories: catalog.categories)
        }
        .task { await catalog.loadCategories() }
        .task(id: searchText) {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                debouncedSearchText = searchText
            } catch {}
        }
        .task(id: "\(debouncedSearchText)|\(selectedCategory ?? 0)") {
            await catalog.refresh(search: debouncedSearchText, category: selectedCategory)
        }
    }

    private func row(_ post: EspacioAPKPost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(post.titleText).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
            if !post.summaryText.isEmpty {
                Text(post.summaryText).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 7) {
                if let date = post.date, date.count >= 10 {
                    Text(String(date.prefix(10)))
                }
                let names = (post.categories ?? []).compactMap { categoryNames[$0] }
                if !names.isEmpty { Text(names.joined(separator: " · ")).lineLimit(1) }
            }
            .font(.caption2).foregroundStyle(.tertiary)
            if post.claimsModifiedContent {
                Label("Modified-content claim · not an official version", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium)).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func refresh() {
        Task { await catalog.refresh(search: debouncedSearchText, category: selectedCategory) }
    }

    private func loadMore() {
        Task { await catalog.loadNextPage(search: debouncedSearchText, category: selectedCategory) }
    }
}

private struct EspacioAPKPostDetail: View {
    let post: EspacioAPKPost
    let categories: [EspacioAPKCategory]
    @Environment(\.dismiss) private var dismiss

    private var categoryNames: [String] {
        let names = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        return (post.categories ?? []).compactMap { names[$0] }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(post.titleText).font(.title2.weight(.bold))
                    if let date = post.date, date.count >= 10 {
                        Label(String(date.prefix(10)), systemImage: "calendar")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if post.claimsModifiedContent {
                        Label("This listing describes modified content. It is not presented as an official game version.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.medium)).foregroundStyle(.orange)
                    }
                    let description = post.contentText.isEmpty ? post.summaryText : post.contentText
                    if !description.isEmpty {
                        Text(description).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                    if !categoryNames.isEmpty {
                        LabeledContent("Categories", value: categoryNames.joined(separator: ", "))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("APK version: not verifiable", systemImage: "questionmark.circle")
                        Label("SHA-256: not published in the catalog feed", systemImage: "number")
                        Label("Signing certificate: not published or verified", systemImage: "signature")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Text("Husk will not download or install an APK from this listing. The article may contain third-party download links; only the EspacioAPK article itself can be opened from this screen.")
                        .font(.footnote).foregroundStyle(.secondary)

                    if let url = post.articleURL {
                        Link(destination: url) {
                            Label("Open EspacioAPK article", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Label("The article link is unavailable or does not point to EspacioAPK.", systemImage: "link.badge.plus")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Listing Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

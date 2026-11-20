// Search › Browse's Charts and New releases pages (Spotify iOS has both as Browse tiles; the
// desktop's routes/charts and routes/new-releases): a coloured header, then the core's shelves.
import SwiftUI

/// The big title both pages open with, over their colour wash (the desktop's `BrowseHeader`).
private struct BrowseHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(title).font(Typo.font(36, .extraBold)).foregroundStyle(.white)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.gutter)
        .padding(.top, 72)
        .padding(.bottom, Space.l)
    }
}

extension View {
    /// The header's colour washing down from under the status bar to the page background.
    fileprivate func browseWash(_ color: String) -> some View {
        background(alignment: .top) {
            LinearGradient(colors: [Color(hex: color), Palette.base], startPoint: .top, endPoint: .bottom)
                .frame(height: 340).ignoresSafeArea(edges: .top)
        }
        .background(Palette.base)
    }
}

struct ChartsView: View {
    @Environment(AppModel.self) private var app
    @State private var page: ChartsPage?
    @State private var failed = false
    @State private var country: String?
    /// A country switch is loading: the old chart dims until the new one arrives.
    @State private var loadingCountry = false
    @State private var attempt = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                BrowseHeader(title: "Charts") { countryPicker }
                if let p = page, p.featured.isEmpty && p.sections.isEmpty {
                    EntityEmptyState(title: "Nothing to show right now", line: "Try again in a little while.", action: "Try again") { attempt += 1 }
                } else if let p = page {
                    if !p.featured.isEmpty { shelf("Featured charts", p.featured) }
                    ForEach(Array(p.sections.enumerated()), id: \.offset) { _, s in
                        if s.kind == "top_artists" { ranked(s) } else { shelf(s.title, s.items.map(\.item)) }
                    }
                    .opacity(loadingCountry ? 0.4 : 1)
                    .animation(.easeOut(duration: 0.2), value: loadingCountry)
                } else {
                    EntityLoadState(failed: failed) { failed = false; attempt += 1 }
                }
            }
            .padding(.bottom, Space.xxl)
        }
        .foregroundStyle(Palette.text)
        .browseWash("#8d67ab")
        .overlay(alignment: .topLeading) { BackButton().padding(.leading, Space.s + 2).padding(.top, 4) }
        .toolbar(.hidden, for: .navigationBar)
        .chromeInset()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("charts-page")
        .task(id: "\(country ?? "")#\(attempt)") {
            loadingCountry = page != nil
            defer { loadingCountry = false }
            do { page = try await app.core.getCharts(country: country) } catch {
                guard !FriendlyError.isCancellation(error) else { return }
                if page == nil { failed = true } else {
                    // The picker goes back to the chart still on screen.
                    let name = country ?? "that country"
                    country = page?.country?.code
                    app.fail(friendlyError(error, "Couldn't load the chart for \(name)"))
                }
            }
        }
    }

    /// The chart's country (Global, or one of YouTube's): remembered by the core once picked.
    @ViewBuilder private var countryPicker: some View {
        if let p = page, !p.countries.isEmpty {
            Menu {
                ForEach(p.countries, id: \.code) { c in
                    Button { country = c.code } label: {
                        if c.code == p.country?.code { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                    }
                }
            } label: {
                HStack(spacing: Space.xs) {
                    Text(p.country?.name ?? "Global").font(Typo.font(14, .bold))
                    Icon(name: "caret-down", size: 14)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 32)
                .overlay(Capsule().stroke(Color.white.opacity(0.7), lineWidth: 1))
            }
            .accessibilityIdentifier("charts-country")
        }
    }

    private func shelf(_ title: String, _ items: [BrowseItem]) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionTitle(title: title)
            CardShelf(items: items)
        }
    }

    /// Top artists: a numbered list with each artist's movement, the first 10 (Spotify's chart rows).
    private func ranked(_ s: ChartSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: s.title).padding(.bottom, Space.s)
            ForEach(Array(s.items.prefix(10).enumerated()), id: \.offset) { i, e in
                Button { app.router.open(e.item) } label: {
                    HStack(spacing: Space.m) {
                        Text("\(e.rank ?? i + 1)").font(Typo.font(16)).foregroundStyle(Palette.subdued).monospacedDigit()
                            .frame(width: 24, alignment: .trailing)
                        trend(e.trend).frame(width: 16)
                        ArtImage(url: e.item.thumbnail, px: 144, circle: true).frame(width: Metrics.rowArt, height: Metrics.rowArt)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.item.title).font(Typo.rowTitle).lineLimit(1)
                            if let sub = e.item.subtitle { Text(sub).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.gutter)
                    .frame(height: Metrics.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chart-artist")
            }
        }
    }

    @ViewBuilder private func trend(_ t: String?) -> some View {
        switch t {
        case "up": Icon(name: "caret-down", fill: true, size: 14).rotationEffect(.degrees(180)).foregroundStyle(Palette.positive).accessibilityLabel("Up")
        case "down": Icon(name: "caret-down", fill: true, size: 14).foregroundStyle(Color(hex: "#f3727f")).accessibilityLabel("Down")
        case "new": Text("NEW").font(Typo.font(9, .bold)).foregroundStyle(Palette.accentText)
        default: Capsule().fill(Palette.subdued).frame(width: 8, height: 2).accessibilityLabel("No change")
        }
    }
}

struct NewReleasesView: View {
    @Environment(AppModel.self) private var app
    @State private var page: NewReleasesPage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                BrowseHeader(title: "New Releases") { EmptyView() }
                if let p = page {
                    if let mix = p.mix {
                        VStack(alignment: .leading, spacing: Space.m) {
                            SectionTitle(title: "Made for new music")
                            CardShelf(items: [mix])
                        }
                    }
                    ForEach(Array(p.sections.enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: Space.m) {
                            SectionTitle(title: s.title)
                            CardShelf(items: s.items)
                        }
                    }
                } else {
                    EntityLoadState(failed: failed) { failed = false; attempt += 1 }
                }
            }
            .padding(.bottom, Space.xxl)
        }
        .foregroundStyle(Palette.text)
        .browseWash("#e8115b")
        .overlay(alignment: .topLeading) { BackButton().padding(.leading, Space.s + 2).padding(.top, 4) }
        .toolbar(.hidden, for: .navigationBar)
        .chromeInset()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-releases-page")
        .task(id: attempt) {
            do { page = try await app.core.getNewReleases() } catch { if page == nil { failed = true } }
        }
    }
}

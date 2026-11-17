import SwiftUI

// The More Apps page and the pieces a host app can place elsewhere.
//
//   MoreAppsPage      the full page: a featured card, then "Not Installed" and
//                     "Installed" lists. Meant for a settings sidebar page.
//   MoreAppsEntryRow  one row that leads to the page, for an About screen.
//
// Both are plain grouped-Form content, so they pick up the host's window
// background and look like the settings rows around them.

// MARK: - Page

public struct MoreAppsPage: View {

    @ObservedObject private var store: MoreAppsStore
    @State private var query = ""

    /// Above this many apps the page gets a search field.
    private static let searchThreshold = 8

    public init(store: MoreAppsStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.apps.count > Self.searchThreshold {
                form.searchable(text: $query, prompt: store.text("search.prompt"))
            } else {
                form
            }
        }
        .onAppear { store.pageAppeared() }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func matches(_ app: MoreApp) -> Bool {
        guard isSearching else { return true }
        let needle = query.trimmingCharacters(in: .whitespaces)
        return app.name.localizedCaseInsensitiveContains(needle)
            || store.tagline(of: app).localizedCaseInsensitiveContains(needle)
    }

    /// The featured app has its own card, so it is left out of the lists unless
    /// the user is searching (the card is hidden then).
    private func listed(installed: Bool) -> [MoreApp] {
        store.apps.filter { app in
            store.installedIDs.contains(app.id) == installed
                && matches(app)
                && (isSearching || app.id != store.featuredID)
        }
    }

    private var form: some View {
        let available = listed(installed: false)
        let installed = listed(installed: true)
        return Form {
            if !isSearching, let featured = store.featured {
                Section {
                    FeaturedCard(store: store, app: featured)
                }
            }
            if !available.isEmpty {
                Section(store.text("section.available")) {
                    ForEach(available) { MoreAppRow(store: store, app: $0) }
                }
            }
            if !installed.isEmpty {
                Section(store.text("section.installed")) {
                    ForEach(installed) { MoreAppRow(store: store, app: $0) }
                }
            }
            if isSearching && available.isEmpty && installed.isEmpty {
                Section {
                    Text(store.text("search.empty"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            Section {
                footer
            }
        }
        .formStyle(.grouped)
    }

    /// Says plainly what Get does, and links to the author's site.
    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(store.text(store.canInstallDirectly ? "footer.install" : "footer.download"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if store.websiteURL != nil {
                Button {
                    store.openWebsite()
                } label: {
                    HStack(spacing: 3) {
                        Text(store.text("footer.website"))
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.caption)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("moreapps.website")
            }
        }
    }
}

// MARK: - Featured card

private struct FeaturedCard: View {
    @ObservedObject var store: MoreAppsStore
    let app: MoreApp

    var body: some View {
        HStack(spacing: 16) {
            MoreAppIcon(store: store, app: app, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.text("featured.label"))
                    .font(.system(size: 10.5, weight: .bold))
                    .kerning(0.5)
                    .foregroundStyle(Color.accentColor)
                Text(app.name)
                    .font(.title2.weight(.bold))
                Text(store.tagline(of: app))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                FailureLine(store: store, app: app)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                MoreAppBadges(store: store, app: app, prominent: true)
                MoreAppActionButton(store: store, app: app, placement: .featured, prominent: true)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { store.openHomepage(of: app) }
        // A grouped Form on macOS ignores `listRowBackground` and
        // `listRowInsets`. The tint is therefore drawn behind the row and made
        // larger than it; the section's rounded box clips it to shape.
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.18), Color.purple.opacity(0.14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .padding(-40)
        )
        // `.contain` keeps the button inside reachable under its own identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("moreapps.featured.\(app.id)")
    }
}

// MARK: - Row

struct MoreAppRow: View {
    @ObservedObject var store: MoreAppsStore
    let app: MoreApp

    var body: some View {
        HStack(spacing: 12) {
            MoreAppIcon(store: store, app: app, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .fontWeight(.semibold)
                Text(store.tagline(of: app))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                FailureLine(store: store, app: app)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                MoreAppBadges(store: store, app: app)
                MoreAppActionButton(store: store, app: app, placement: .list)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { store.openHomepage(of: app) }
        .help(store.text("row.help", app.name))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("moreapps.row.\(app.id)")
    }
}

// MARK: - Badges

/// The round icon buttons to the left of a row's main button: a GitHub mark
/// when the app's source is public (opens the repository), and an App Store
/// mark when the app is on the Mac App Store (opens its store page).
///
/// They sit beside the main button, at its height, so everything clickable in
/// a row is in one place.
struct MoreAppBadges: View {
    @ObservedObject var store: MoreAppsStore
    let app: MoreApp
    /// The larger size, for the featured card.
    var prominent = false

    /// The main button of an App Store app that is not installed already says
    /// "App Store" and opens the same page, so the mark would repeat it.
    private var showsStoreBadge: Bool {
        guard app.isAppStore else { return false }
        switch store.state(for: app) {
        case .installed, .unsupported: return true
        default: return false
        }
    }

    var body: some View {
        if showsStoreBadge {
            BadgeButton(badge: .appStore, appID: app.id, prominent: prominent,
                        help: store.text("badge.appstore.help", app.name)) {
                store.openStorePage(of: app)
            }
        }
        if app.github != nil {
            BadgeButton(badge: .github, appID: app.id, prominent: prominent,
                        help: store.text("badge.github.help", app.name)) {
                store.openSource(of: app)
            }
        }
    }
}

private struct BadgeButton: View {
    let badge: MoreAppsEvent.Badge
    let appID: String
    let prominent: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    // The same height as `MoreAppActionButton`'s capsule, so the two line up.
    private var diameter: CGFloat { prominent ? 28 : 24 }
    private var glyph: CGFloat { prominent ? 15 : 13 }

    var body: some View {
        Button(action: action) {
            Image(nsImage: Self.image(for: badge))
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .frame(width: glyph, height: glyph)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier("moreapps.badge.\(badge.rawValue).\(appID)")
    }

    /// The glyphs are bundled as black-on-clear images and drawn as templates,
    /// so they take the text colour in light and dark mode.
    private static func image(for badge: MoreAppsEvent.Badge) -> NSImage {
        let name = badge == .github ? "moreapps-badge-github" : "moreapps-badge-appstore"
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return NSImage() }
        image.isTemplate = true
        return image
    }
}

/// The reason an install failed, with the way out, shown under the tagline.
private struct FailureLine: View {
    @ObservedObject var store: MoreAppsStore
    let app: MoreApp

    var body: some View {
        if case .failed(let error) = store.state(for: app) {
            HStack(spacing: 8) {
                Text(store.failureText(error))
                    .foregroundStyle(.red)
                Button(store.text("error.browser")) {
                    store.downloadInBrowser(app)
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .padding(.top, 1)
        }
    }
}

struct MoreAppIcon: View {
    @ObservedObject var store: MoreAppsStore
    let app: MoreApp
    let size: CGFloat

    var body: some View {
        Image(nsImage: store.icon(for: app))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Button

/// The button at the end of a row. One control that changes with the app's
/// state: Get → progress ring (click to cancel) → spinner → Open.
struct MoreAppActionButton: View {
    @ObservedObject var store: MoreAppsStore
    let app: MoreApp
    let placement: MoreAppsEvent.Placement
    var prominent = false

    @State private var hovering = false

    private var width: CGFloat { prominent ? 76 : 62 }
    private var height: CGFloat { prominent ? 28 : 24 }

    var body: some View {
        let state = store.state(for: app)
        Group {
            switch state {
            case .unsupported(let minOS):
                Text(store.text("requires.macos", minOS))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .installing:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: width, height: height)
                    .help(store.text("installing.help"))
            default:
                Button {
                    store.performPrimaryAction(for: app, placement: placement)
                } label: {
                    label(for: state)
                        .frame(minWidth: width, minHeight: height)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(help(for: state))
            }
        }
        .accessibilityIdentifier("moreapps.action.\(app.id)")
    }

    @ViewBuilder
    private func label(for state: MoreAppState) -> some View {
        switch state {
        case .downloading(let fraction):
            ProgressRing(fraction: fraction)
        case .installed:
            pill(store.text("action.open"), emphasized: false)
        case .failed:
            pill(store.text("action.retry"), emphasized: true)
        default:
            pill(store.text(app.isAppStore ? "action.appstore" : "action.get"), emphasized: true)
        }
    }

    /// A capsule label. `emphasized` is the call to action (Get); the plain form
    /// is for Open, which should not compete with it.
    private func pill(_ title: String, emphasized: Bool) -> some View {
        let filled = prominent && emphasized
        return Text(title)
            .font(.system(size: prominent ? 13 : 12, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(filled ? Color.white : (emphasized ? Color.accentColor : Color.primary))
            .padding(.horizontal, prominent ? 16 : 12)
            .frame(minWidth: width, minHeight: height)
            .background(
                Capsule().fill(filled ? Color.accentColor.opacity(hovering ? 0.85 : 1)
                                      : Color.primary.opacity(hovering ? 0.14 : 0.08))
            )
    }

    private func help(for state: MoreAppState) -> String {
        switch state {
        case .downloading: return store.text("downloading.help")
        case .installed:   return store.text("open.help", app.name)
        default:           return ""
        }
    }
}

/// Download progress with a stop square in the middle.
private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.15), value: fraction)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - Entry row

/// A single row that leads to the More Apps page: a title, a small stack of
/// app icons, the number of apps and a chevron. `leading` is the host's own row
/// icon, so the row matches its neighbours.
public struct MoreAppsEntryRow<Leading: View>: View {

    @ObservedObject private var store: MoreAppsStore
    private let title: String
    private let leading: Leading
    private let action: () -> Void

    public init(store: MoreAppsStore, title: String,
                @ViewBuilder leading: () -> Leading, action: @escaping () -> Void) {
        self.store = store
        self.title = title
        self.leading = leading()
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                leading
                Text(title)
                Spacer(minLength: 8)
                HStack(spacing: -6) {
                    ForEach(store.apps.prefix(4)) { app in
                        MoreAppIcon(store: store, app: app, size: 22)
                    }
                }
                Text(store.text("entry.count", store.apps.count))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("moreapps.entry")
    }
}

import AppKit
import Combine
import UniformTypeIdentifiers

/// What the button next to an app currently does.
public enum MoreAppState: Equatable {
    /// Not installed; the button offers to get it.
    case available
    /// Download in progress, 0 to 1. Clicking cancels.
    case downloading(Double)
    /// Downloaded; being verified and copied into the Applications folder.
    case installing
    /// Installed; the button opens it.
    case installed
    /// The last attempt failed; the button retries.
    case failed(MoreAppsInstallError)
    /// This Mac's system is older than the app needs.
    case unsupported(minOS: String)
}

/// The model behind the More Apps page: which apps to list, what state each one
/// is in, and the actions the buttons trigger.
///
/// Use it from the main thread only. (It is deliberately not `@MainActor`, so a
/// host app can create it from ordinary AppKit setup code.) Work that leaves the
/// main thread hops back before touching any property.
public final class MoreAppsStore: ObservableObject, @unchecked Sendable {

    public struct Configuration {
        /// Bundle id of the app showing the page. That app is left out of its
        /// own list. A `.debug`-style suffix is tolerated.
        public var hostBundleID: String
        /// Where to look for a newer catalog, tried in order.
        public var catalogURLs: [URL]
        /// Linked at the bottom of the page. Nil hides the link.
        public var websiteURL: URL?
        /// Language code for the page's own texts and the taglines (`zh-Hans`).
        /// Nil follows the system.
        public var language: String?

        public init(hostBundleID: String = Bundle.main.bundleIdentifier ?? "",
                    catalogURLs: [URL] = MoreAppsDefaults.catalogURLs,
                    websiteURL: URL? = MoreAppsDefaults.websiteURL,
                    language: String? = nil) {
            self.hostBundleID = hostBundleID
            self.catalogURLs = catalogURLs
            self.websiteURL = websiteURL
            self.language = language
        }
    }

    // MARK: Published state

    /// The apps to show, in display order: not installed, then not supported on
    /// this system, then already installed.
    @Published public private(set) var apps: [MoreApp] = []
    @Published public private(set) var states: [String: MoreAppState] = [:]
    /// The app shown in the large card at the top, if any is left to install.
    @Published public private(set) var featuredID: String?
    /// The apps that were installed when the list was last arranged. The page
    /// groups by this snapshot, so a row does not jump to another section the
    /// instant its install finishes.
    @Published public private(set) var installedIDs: Set<String> = []
    @Published private var iconRevision = 0

    /// Language code for texts and taglines; nil follows the system.
    public var language: String? {
        didSet { if oldValue != language { objectWillChange.send() } }
    }
    /// Receives every analytics event. The host forwards them to its own
    /// analytics, behind its own opt-out.
    public var onEvent: ((MoreAppsEvent) -> Void)?
    /// How the user is about to reach the page (`about`, `menu`). Set it just
    /// before navigating; it is reported with the next view and then resets to
    /// `sidebar`.
    public var nextViewSource = "sidebar"
    public let websiteURL: URL?

    // MARK: Private state

    private var catalog: MoreAppsCatalog
    private var catalogSource: URL?
    /// Revision of the copy shipped in the package; a fetched catalog older
    /// than this is ignored.
    private let bundledRevision: Int
    private let loader: CatalogLoader
    private let installer: AppInstaller
    private let hostBundleID: String
    /// The team that signed the host app. Downloads must be signed by the same
    /// team. Nil (unsigned or ad-hoc host) disables in-app installing.
    private let hostTeamID: String?
    private let isSandboxed: Bool
    private let installedLocation: (String) -> URL?

    private struct Job { let token: Int; let task: Task<Void, Never> }
    private var jobs: [String: Job] = [:]
    private var nextToken = 0
    private var icons: [String: NSImage] = [:]
    private var iconFetches = Set<String>()
    private var lastCatalogFetch: Date?
    private var activeObserver: NSObjectProtocol?

    private static let catalogRefreshInterval: TimeInterval = 6 * 60 * 60

    // MARK: Lifecycle

    public convenience init(configuration: Configuration = Configuration()) {
        self.init(configuration: configuration,
                  catalog: nil,
                  hostTeamID: CodeSignature.teamIdentifier(ofBundleAt: Bundle.main.bundleURL),
                  installedLocation: Self.installedLocation(ofBundleID:))
    }

    /// Where the app with this bundle id is installed, or nil.
    ///
    /// Only copies inside an Applications folder count. macOS also knows about
    /// copies lying elsewhere (a build folder, a mounted disk image, a download
    /// that was never moved); offering "Open" for one of those would be wrong,
    /// and Get should still be able to install the app properly.
    static func installedLocation(ofBundleID bundleID: String) -> URL? {
        let folders = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).first { url in
            let path = url.standardizedFileURL.path
            return folders.contains { path.hasPrefix($0) } && FileManager.default.fileExists(atPath: path)
        }
    }

    /// Designated initializer; the extra parameters exist for tests.
    init(configuration: Configuration,
         catalog: MoreAppsCatalog?,
         hostTeamID: String?,
         installedLocation: @escaping (String) -> URL?,
         installer: AppInstaller = AppInstaller()) {
        hostBundleID = configuration.hostBundleID
        websiteURL = configuration.websiteURL
        language = configuration.language
        self.hostTeamID = hostTeamID
        self.installedLocation = installedLocation
        self.installer = installer
        isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        loader = CatalogLoader(urls: configuration.catalogURLs, hostBundleID: configuration.hostBundleID)

        if let catalog {
            self.catalog = catalog
            bundledRevision = catalog.revision
        } else {
            let bundled = MoreAppsCatalog.bundled()
            bundledRevision = bundled.revision
            if let cached = loader.cached(), cached.catalog.revision > bundled.revision {
                self.catalog = cached.catalog
                catalogSource = cached.source
            } else {
                self.catalog = bundled
            }
        }
        arrange()

        // Coming back to the host app is when the installed set may have
        // changed: an install just finished, or the user removed an app.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.arrange()
        }
    }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        jobs.values.forEach { $0.task.cancel() }
    }

    // MARK: Reading

    public func state(for app: MoreApp) -> MoreAppState {
        states[app.id] ?? .available
    }

    public var featured: MoreApp? {
        apps.first { $0.id == featuredID }
    }

    /// The catalog id of the host app (`anydrag`), used as the referrer handed
    /// to apps it installs.
    public var hostAppID: String {
        if let own = catalog.apps.first(where: isHost) { return own.id }
        let last = hostBundleID.split(separator: ".").last.map { $0.lowercased() } ?? "unknown"
        return MoreApp.isValidID(last) ? last : "unknown"
    }

    /// Whether Get can install for the user, as opposed to sending them to a
    /// browser download.
    public var canInstallDirectly: Bool {
        hostTeamID != nil && !isSandboxed
    }

    // MARK: Arranging

    struct Arrangement: Equatable {
        var available: [MoreApp] = []
        var unsupported: [MoreApp] = []
        var installed: [MoreApp] = []
    }

    /// Splits the catalog into the three display groups, keeping catalog order
    /// inside each. Leaves out the host app itself and any app with no build for
    /// this Mac's processor.
    static func arrangement(of apps: [MoreApp], hostBundleID: String, architecture: MoreAppsArchitecture,
                            system: OperatingSystemVersion, isInstalled: (MoreApp) -> Bool) -> Arrangement {
        var result = Arrangement()
        for app in apps where !isHost(app, hostBundleID: hostBundleID) {
            if !app.isAppStore && app.diskImageURL(for: architecture) == nil { continue }
            if isInstalled(app) {
                result.installed.append(app)
            } else if !app.isSupported(on: system) {
                result.unsupported.append(app)
            } else {
                result.available.append(app)
            }
        }
        return result
    }

    static func isHost(_ app: MoreApp, hostBundleID: String) -> Bool {
        hostBundleID == app.bundleID || hostBundleID.hasPrefix(app.bundleID + ".")
    }

    private func isHost(_ app: MoreApp) -> Bool {
        Self.isHost(app, hostBundleID: hostBundleID)
    }

    /// Re-reads which apps are installed and rebuilds the list. Called when the
    /// page appears, when the host app becomes active, and after a newer catalog
    /// arrives.
    public func arrange() {
        let groups = Self.arrangement(
            of: catalog.apps, hostBundleID: hostBundleID, architecture: .current,
            system: ProcessInfo.processInfo.operatingSystemVersion,
            isInstalled: { [installedLocation] in installedLocation($0.bundleID) != nil })

        var next: [String: MoreAppState] = [:]
        for app in groups.installed {
            next[app.id] = isBusy(app) ? states[app.id] : .installed
        }
        for app in groups.unsupported {
            next[app.id] = .unsupported(minOS: app.minOS ?? "")
        }
        for app in groups.available {
            switch states[app.id] {
            case .downloading, .installing, .failed: next[app.id] = states[app.id]
            default: next[app.id] = .available
            }
        }

        let ordered = groups.available + groups.unsupported + groups.installed
        let installed = Set(groups.installed.map(\.id))
        let featured = groups.available.first?.id
        // Assign only what changed, so an unchanged list does not redraw.
        if apps != ordered { apps = ordered }
        if states != next { states = next }
        if installedIDs != installed { installedIDs = installed }
        if featuredID != featured { featuredID = featured }
    }

    private func isBusy(_ app: MoreApp) -> Bool {
        switch states[app.id] {
        case .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: Page lifecycle

    /// Call when the page comes on screen.
    public func pageAppeared() {
        arrange()
        refreshCatalogIfDue()
        emit(.viewed(source: nextViewSource, appCount: apps.count))
        nextViewSource = "sidebar"
    }

    private func refreshCatalogIfDue() {
        if let lastCatalogFetch, Date().timeIntervalSince(lastCatalogFetch) < Self.catalogRefreshInterval { return }
        lastCatalogFetch = Date()
        Task { [weak self, loader] in
            guard let loaded = await loader.fetch() else { return }
            await MainActor.run { [weak self] in self?.adopt(loaded) }
        }
    }

    /// Takes over a catalog that just came from the network.
    ///
    /// The network copy is the author's current word, so it replaces whatever
    /// is in use even when its revision is lower. That is what lets a catalog
    /// published by mistake be withdrawn. Only the bundled copy sets a floor:
    /// an app update may ship a newer catalog than a stale server has.
    func adopt(_ loaded: CatalogLoader.Loaded) {
        guard loaded.catalog.revision >= bundledRevision, loaded.catalog != catalog else { return }
        catalog = loaded.catalog
        catalogSource = loaded.source
        arrange()
    }

    // MARK: Actions

    /// The button next to an app was clicked.
    public func performPrimaryAction(for app: MoreApp, placement: MoreAppsEvent.Placement) {
        switch state(for: app) {
        case .available, .failed:
            get(app, placement: placement)
        case .downloading:
            cancel(app)
        case .installed:
            open(app)
        case .installing, .unsupported:
            break
        }
    }

    private func get(_ app: MoreApp, placement: MoreAppsEvent.Placement) {
        emit(.getClicked(app, placement: placement))
        switch app.install {
        case .appStore(let url):
            openAppStore(url)
        case .diskImage:
            guard let url = app.diskImageURL(for: .current) else { return }
            guard canInstallDirectly, let hostTeamID else {
                // This host cannot install for the user (it is sandboxed, or it
                // is not signed with a team). Let the browser download the image.
                NSWorkspace.shared.open(url)
                emit(.manualFallback(app, via: "browser"))
                return
            }
            startInstall(app, from: url, teamID: hostTeamID)
        }
    }

    private func startInstall(_ app: MoreApp, from url: URL, teamID: String) {
        let id = app.id
        let started = Date()
        nextToken += 1
        let token = nextToken
        states[id] = .downloading(0)

        let task = Task { [weak self, installer] in
            do {
                let download = try await installer.download(url) { [weak self] fraction in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isCurrent(id, token), case .downloading = self.states[id] else { return }
                        self.states[id] = .downloading(fraction)
                    }
                }
                // The user may have cancelled in the instant the download ended.
                let proceed = await MainActor.run { [weak self] () -> Bool in
                    guard let self, self.isCurrent(id, token) else { return false }
                    self.states[id] = .installing
                    return true
                }
                guard proceed else {
                    installer.discard(download)
                    return
                }
                let outcome = try await installer.install(app, from: download, teamID: teamID)
                await MainActor.run { [weak self] in self?.finish(app, token: token, outcome: outcome, started: started) }
            } catch let error as MoreAppsInstallError {
                await MainActor.run { [weak self] in self?.fail(app, token: token, error: error) }
            } catch is CancellationError {
                // `cancel(_:)` already reset the row and reported the event.
            } catch {
                await MainActor.run { [weak self] in
                    self?.fail(app, token: token, error: MoreAppsInstallError(stage: .download, reason: "unexpected"))
                }
            }
        }
        jobs[id] = Job(token: token, task: task)
    }

    /// True while `token` still identifies the running install of app `id`
    /// (false after a cancel, or once a newer attempt has started).
    private func isCurrent(_ id: String, _ token: Int) -> Bool {
        jobs[id]?.token == token
    }

    private func cancel(_ app: MoreApp) {
        guard let job = jobs.removeValue(forKey: app.id) else { return }
        job.task.cancel()
        states[app.id] = .available
        emit(.installCancelled(app))
    }

    private func finish(_ app: MoreApp, token: Int, outcome: AppInstaller.Outcome, started: Date) {
        guard isCurrent(app.id, token) else { return }
        jobs[app.id] = nil
        switch outcome {
        case .installed(let url):
            states[app.id] = .installed
            emit(.installSucceeded(app, seconds: Int(Date().timeIntervalSince(started).rounded())))
            launch(url, referred: true)
        case .alreadyPresent(let url):
            // The app turned out to be in the Applications folder already.
            // Nothing was installed, so no install is reported; just open it.
            states[app.id] = .installed
            launch(url, referred: false)
        case .needsManualInstall(let diskImage):
            // The Applications folder is not writable for this account. Show the
            // verified disk image so the user can drag the app themselves.
            states[app.id] = .available
            NSWorkspace.shared.open(diskImage)
            emit(.manualFallback(app, via: "disk_image"))
        }
    }

    private func fail(_ app: MoreApp, token: Int, error: MoreAppsInstallError) {
        guard isCurrent(app.id, token) else { return }
        jobs[app.id] = nil
        states[app.id] = .failed(error)
        emit(.installFailed(app, error: error))
    }

    private func open(_ app: MoreApp) {
        guard let url = installedLocation(app.bundleID) else {
            // It was removed since the list was built.
            arrange()
            return
        }
        emit(.openClicked(app))
        launch(url, referred: false)
    }

    private func launch(_ url: URL, referred: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        if referred {
            // Tells the launched app which sibling installed it. An app that
            // does not look for the variable is unaffected.
            configuration.environment = [MoreApps.referrerEnvironmentKey: hostAppID]
        }
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    private func openAppStore(_ url: URL) {
        // The `macappstore` scheme opens the App Store app directly instead of
        // going through a browser tab first.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "macappstore"
        if let direct = components?.url, NSWorkspace.shared.open(direct) { return }
        NSWorkspace.shared.open(url)
    }

    /// The row itself (not its button) was clicked.
    public func openHomepage(of app: MoreApp) {
        guard let url = app.homepage ?? websiteURL else { return }
        emit(.homepageClicked(app))
        NSWorkspace.shared.open(url)
    }

    /// "Download in browser", offered on a row whose install failed.
    public func downloadInBrowser(_ app: MoreApp) {
        guard let url = app.diskImageURL(for: .current) ?? app.homepage else { return }
        states[app.id] = .available
        NSWorkspace.shared.open(url)
        emit(.manualFallback(app, via: "browser"))
    }

    public func openWebsite() {
        guard let websiteURL else { return }
        NSWorkspace.shared.open(websiteURL)
    }

    private func emit(_ event: MoreAppsEvent) {
        onEvent?(event)
    }

    // MARK: Icons

    private static let placeholderIcon = NSWorkspace.shared.icon(for: .applicationBundle)

    /// The app's icon: bundled with the package, or downloaded earlier, or a
    /// generic one while the real icon is fetched.
    public func icon(for app: MoreApp) -> NSImage {
        if let image = icons[app.id] { return image }
        if let image = CatalogLoader.bundledIcon(for: app) ?? loader.cachedIcon(for: app) {
            icons[app.id] = image
            return image
        }
        if app.icon != nil, iconFetches.insert(app.id).inserted {
            let source = catalogSource
            Task { [weak self, loader] in
                guard let image = await loader.fetchIcon(for: app, catalogSource: source) else {
                    // Forget the attempt, so the icon is tried again next time.
                    await MainActor.run { [weak self] in _ = self?.iconFetches.remove(app.id) }
                    return
                }
                await MainActor.run { [weak self] in
                    self?.icons[app.id] = image
                    self?.iconRevision += 1
                }
            }
        }
        return Self.placeholderIcon
    }

    // MARK: Texts

    /// The language used for taglines.
    public var languageCode: String {
        language ?? Bundle.module.preferredLocalizations.first ?? "en"
    }

    public func tagline(of app: MoreApp) -> String {
        app.tagline(forLanguage: languageCode)
    }

    /// A text from the package's own string table, in the configured language.
    public func text(_ key: String) -> String {
        stringsBundle.localizedString(forKey: key, value: key, table: "MoreApps")
    }

    public func text(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }

    private var stringsBundle: Bundle {
        guard let language else { return .module }
        // SwiftPM may store the folder as `zh-hans.lproj`; try both spellings.
        for name in [language, language.lowercased()] {
            if let path = Bundle.module.path(forResource: name, ofType: "lproj"), let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return .module
    }

    /// The one-line reason shown under a row whose install failed.
    public func failureText(_ error: MoreAppsInstallError) -> String {
        switch error.stage {
        case .download: return text("error.download")
        case .mount:    return text("error.mount")
        case .verify:   return text("error.verify")
        case .copy:     return text("error.copy")
        }
    }
}

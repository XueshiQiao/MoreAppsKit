import XCTest
@testable import MoreAppsKit

final class StoreTests: XCTestCase {

    private func app(_ id: String, minOS: String? = nil, appStore: Bool = false,
                     arm64Only: Bool = false) -> MoreApp {
        let dmg = URL(string: "https://example.com/\(id).dmg")!
        let install: MoreApp.Install = appStore
            ? .appStore(URL(string: "https://apps.apple.com/app/id1")!)
            : (arm64Only ? .diskImage(universal: nil, arm64: dmg, x86_64: nil)
                         : .diskImage(universal: dmg, arm64: nil, x86_64: nil))
        return MoreApp(id: id, name: id.capitalized, bundleID: "com.example.\(id)",
                       tagline: ["en": "About \(id)", "zh-Hans": "关于 \(id)"],
                       homepage: URL(string: "https://example.com/\(id)"), minOS: minOS, install: install)
    }

    private let system = OperatingSystemVersion(majorVersion: 13, minorVersion: 5, patchVersion: 0)

    // MARK: Arrangement

    func testGroupsKeepCatalogOrderAndLeaveOutTheHost() {
        let apps = [app("one"), app("host"), app("two"), app("three", minOS: "14.0"), app("four")]
        let groups = MoreAppsStore.arrangement(
            of: apps, hostBundleID: "com.example.host", architecture: .arm64, system: system,
            isInstalled: { $0.id == "two" })
        XCTAssertEqual(groups.available.map(\.id), ["one", "four"])
        XCTAssertEqual(groups.unsupported.map(\.id), ["three"])
        XCTAssertEqual(groups.installed.map(\.id), ["two"])
    }

    func testHostIsRecognisedWithADebugSuffixButNotByASharedPrefix() {
        let paste = app("paste")
        XCTAssertTrue(MoreAppsStore.isHost(paste, hostBundleID: "com.example.paste"))
        XCTAssertTrue(MoreAppsStore.isHost(paste, hostBundleID: "com.example.paste.debug"))
        XCTAssertFalse(MoreAppsStore.isHost(paste, hostBundleID: "com.example.pastex"))
        XCTAssertFalse(MoreAppsStore.isHost(paste, hostBundleID: "com.example"))
    }

    func testAppWithoutABuildForThisProcessorIsHidden() {
        let apps = [app("arm", arm64Only: true), app("store", appStore: true)]
        let intel = MoreAppsStore.arrangement(of: apps, hostBundleID: "x", architecture: .x86_64, system: system,
                                              isInstalled: { _ in false })
        XCTAssertEqual(intel.available.map(\.id), ["store"])
        let arm = MoreAppsStore.arrangement(of: apps, hostBundleID: "x", architecture: .arm64, system: system,
                                            isInstalled: { _ in false })
        XCTAssertEqual(arm.available.map(\.id), ["arm", "store"])
    }

    func testAnInstalledAppIsListedAsInstalledEvenWhenTheSystemIsTooOld() {
        // It is already running here, so "requires a newer macOS" would be wrong.
        let groups = MoreAppsStore.arrangement(of: [app("old", minOS: "99.0")], hostBundleID: "x",
                                               architecture: .arm64, system: system, isInstalled: { _ in true })
        XCTAssertEqual(groups.installed.map(\.id), ["old"])
        XCTAssertTrue(groups.unsupported.isEmpty)
    }

    // MARK: Store

    private func makeStore(installed: Set<String> = [], language: String? = "en",
                           host: String = "com.example.host") -> (MoreAppsStore, () -> [MoreAppsEvent]) {
        let catalog = MoreAppsCatalog(revision: 1, apps: [
            app("host"), app("one"), app("two"), app("store", appStore: true), app("future", minOS: "99.0"),
        ])
        let store = MoreAppsStore(
            configuration: .init(hostBundleID: host, catalogURLs: [], websiteURL: nil, language: language),
            catalog: catalog, hostTeamID: nil,
            installedLocation: { installed.contains($0) ? URL(fileURLWithPath: "/tmp/\($0).app") : nil })
        var events: [MoreAppsEvent] = []
        store.onEvent = { events.append($0) }
        return (store, { events })
    }

    func testListOrderStatesAndFeaturedApp() {
        let (store, _) = makeStore(installed: ["com.example.one"])
        XCTAssertEqual(store.apps.map(\.id), ["two", "store", "future", "one"])
        XCTAssertEqual(store.featuredID, "two")
        XCTAssertEqual(store.installedIDs, ["one"])
        XCTAssertEqual(store.state(for: store.apps[0]), .available)
        XCTAssertEqual(store.state(for: store.apps[2]), .unsupported(minOS: "99.0"))
        XCTAssertEqual(store.state(for: store.apps[3]), .installed)
    }

    func testNothingIsFeaturedOnceEverythingIsInstalled() {
        let (store, _) = makeStore(installed: ["com.example.one", "com.example.two", "com.example.store"])
        XCTAssertNil(store.featured)
        XCTAssertEqual(store.apps.map(\.id), ["future", "one", "two", "store"])
    }

    func testWithAHostThatIsNotInTheCatalogNothingIsLeftOut() {
        let (store, _) = makeStore(host: "org.example.Somebody-Else")
        XCTAssertEqual(store.apps.first?.id, "host")   // the catalog's "host" app is now just another app
    }

    func testViewEventCarriesTheSourceOnceThenResets() {
        let (store, events) = makeStore()
        store.nextViewSource = "about"
        store.pageAppeared()
        store.pageAppeared()
        XCTAssertEqual(events(), [
            MoreAppsEvent(name: "more_apps_viewed", properties: ["source": "about", "apps": "4"]),
            MoreAppsEvent(name: "more_apps_viewed", properties: ["source": "sidebar", "apps": "4"]),
        ])
    }

    func testTextsAndTaglinesFollowTheConfiguredLanguage() {
        let (store, _) = makeStore(language: "zh-Hans")
        XCTAssertEqual(store.text("action.get"), "获取")
        XCTAssertEqual(store.text("entry.count", 5), "5 个")
        XCTAssertEqual(store.tagline(of: store.apps[0]), "关于 one")
        store.language = "en"
        XCTAssertEqual(store.text("action.get"), "Get")
        XCTAssertEqual(store.text("requires.macos", "14.0"), "Requires macOS 14.0")
        XCTAssertEqual(store.tagline(of: store.apps[0]), "About one")
    }

    func testAHostsOwnLanguageSpellingFindsTheNearestTable() {
        let (store, _) = makeStore(language: "zh")        // HyperCapslock calls Chinese `zh`
        XCTAssertEqual(store.text("action.get"), "获取")
        XCTAssertEqual(store.tagline(of: store.apps[0]), "关于 one")
        store.language = "zh-CN"
        XCTAssertEqual(store.text("action.get"), "获取")
        store.language = "ja"
        XCTAssertEqual(store.text("action.open"), "開く")
        XCTAssertEqual(store.tagline(of: store.apps[0]), "About one")   // no Japanese tagline: English
        store.language = "de"
        XCTAssertEqual(store.text("entry.count", 3), "3 Apps")
        store.language = "pt-BR"                                         // not in the package: English
        XCTAssertEqual(store.text("action.get"), "Get")
    }

    func testNetworkCatalogReplacesTheCurrentOneButNeverGoesBelowTheBundledCopy() {
        // The store starts from revision 1 (standing in for the bundled copy).
        let (store, _) = makeStore()
        func fetched(_ revision: Int, _ ids: [String]) -> CatalogLoader.Loaded {
            .init(catalog: MoreAppsCatalog(revision: revision, apps: ids.map { app($0) }), source: nil)
        }
        store.adopt(fetched(900, ["mistake"]))
        XCTAssertEqual(store.apps.map(\.id), ["mistake"])
        // A lower revision from the network still wins: that is how a catalog
        // published by mistake is withdrawn.
        store.adopt(fetched(2, ["one", "two"]))
        XCTAssertEqual(store.apps.map(\.id), ["one", "two"])
        // Older than the copy the app shipped with: ignored.
        store.adopt(fetched(0, ["ancient"]))
        XCTAssertEqual(store.apps.map(\.id), ["one", "two"])
    }

    func testCatalogFetchEventSaysWhichAddressesAnsweredAndWhichWasUsed() throws {
        let github = try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/o/r/main/apps.json"))
        let cdn = try XCTUnwrap(URL(string: "https://cdn.jsdelivr.net/gh/o/r@main/apps.json"))
        let fastly = try XCTUnwrap(URL(string: "https://fastly.jsdelivr.net/gh/o/r@main/apps.json"))
        let other = try XCTUnwrap(URL(string: "https://lists.example.com/apps.json"))
        let catalog = MoreAppsCatalog(revision: 7, apps: [app("one")])

        let some = CatalogLoader.FetchReport(
            loaded: .init(catalog: catalog, source: cdn),
            outcomes: [.init(url: github, answered: false), .init(url: cdn, answered: true),
                       .init(url: fastly, answered: true), .init(url: other, answered: false)])
        XCTAssertEqual(MoreAppsEvent.catalogFetched(some),
                       MoreAppsEvent(name: "more_apps_catalog_fetched", properties: [
                           "used": "jsdelivr", "revision": "7", "github": "failed", "jsdelivr": "ok",
                           "jsdelivr_fastly": "ok", "lists_example_com": "failed",
                       ]))

        // No address reachable: still an event, and it says so.
        let none = CatalogLoader.FetchReport(
            loaded: nil, outcomes: [.init(url: github, answered: false), .init(url: cdn, answered: false)])
        XCTAssertEqual(MoreAppsEvent.catalogFetched(none).properties,
                       ["used": "none", "github": "failed", "jsdelivr": "failed"])
    }

    func testEventPropertiesUseTheAgreedNames() {
        let demo = app("demo")
        XCTAssertEqual(MoreAppsEvent.getClicked(demo, placement: .featured),
                       MoreAppsEvent(name: "more_apps_get_clicked",
                                     properties: ["target": "demo", "kind": "dmg", "placement": "featured"]))
        XCTAssertEqual(MoreAppsEvent.getClicked(app("s", appStore: true), placement: .list).properties["kind"], "app_store")
        XCTAssertEqual(MoreAppsEvent.installFailed(demo, error: .init(stage: .verify, reason: "signature")),
                       MoreAppsEvent(name: "more_apps_install_failed",
                                     properties: ["target": "demo", "stage": "verify", "reason": "signature"]))
        XCTAssertEqual(MoreAppsEvent.installSucceeded(demo, seconds: 12).properties, ["target": "demo", "seconds": "12"])
        XCTAssertEqual(MoreAppsEvent.badgeClicked(demo, badge: .github),
                       MoreAppsEvent(name: "more_apps_badge_clicked", properties: ["target": "demo", "badge": "github"]))
        XCTAssertEqual(MoreAppsEvent.badgeClicked(demo, badge: .appStore).properties["badge"], "app_store")
    }
}

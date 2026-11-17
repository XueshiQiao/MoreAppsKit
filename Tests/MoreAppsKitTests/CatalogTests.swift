import XCTest
@testable import MoreAppsKit

final class CatalogTests: XCTestCase {

    private func catalog(_ json: String) throws -> MoreAppsCatalog {
        try MoreAppsCatalog.decode(Data(json.utf8))
    }

    private func app(id: String = "demo", install: String, extra: String = "") -> String {
        """
        {"id":"\(id)","name":"Demo","bundleId":"com.example.\(id)","tagline":{"en":"English","zh-Hans":"中文"},
         \(extra) "install": \(install)}
        """
    }

    // MARK: The bundled catalog

    func testBundledCatalogListsTheAppsInTheAgreedOrder() {
        let bundled = MoreAppsCatalog.bundled()
        XCTAssertEqual(bundled.schema, MoreAppsCatalog.supportedSchema)
        // The three apps that are not on the author's website come last.
        XCTAssertEqual(bundled.apps.map(\.id), [
            "pastepaw", "anydrag", "qduo", "hypercapslock", "ccswitcher", "netstat-cat",
            "xtools", "attache", "wepaste",
        ])
    }

    func testEveryBundledAppIsComplete() {
        for app in MoreAppsCatalog.bundled().apps {
            XCTAssertFalse(app.tagline(forLanguage: "en").isEmpty, "\(app.id) has no English tagline")
            XCTAssertNotNil(app.tagline["zh-Hans"], "\(app.id) has no Chinese tagline")
            XCTAssertNotNil(app.homepage, "\(app.id) has no homepage")
            XCTAssertNotNil(app.minOS.flatMap(MoreApp.parseVersion), "\(app.id) has no usable minOS")
            XCTAssertNotNil(CatalogLoader.bundledIcon(for: app), "\(app.id) has no bundled icon")
            if !app.isAppStore {
                XCTAssertNotNil(app.diskImageURL(for: .arm64), "\(app.id) has no Apple silicon download")
                XCTAssertNotNil(app.diskImageURL(for: .x86_64), "\(app.id) has no Intel download")
            }
        }
    }

    func testEveryStringTableHasTheSameKeys() throws {
        func keys(_ language: String) throws -> Set<String> {
            let path = try XCTUnwrap(Bundle.moreAppsKit.path(forResource: language, ofType: "lproj")
                                     ?? Bundle.moreAppsKit.path(forResource: language.lowercased(), ofType: "lproj"))
            let file = try XCTUnwrap(Bundle(path: path)?.url(forResource: "MoreApps", withExtension: "strings"))
            let table = try XCTUnwrap(NSDictionary(contentsOf: file) as? [String: String])
            return Set(table.keys)
        }
        let english = try keys("en")
        XCTAssertFalse(english.isEmpty)
        for language in ["zh-Hans", "ja", "de", "es", "fr"] {
            XCTAssertEqual(english, try keys(language), "\(language) has different keys than en")
        }
    }

    // MARK: Choosing between the published copies

    func testTheNewestPublishedCopyWinsAndTheFirstAddressBreaksATie() {
        XCTAssertNil(CatalogLoader.newest([]))
        XCTAssertEqual(CatalogLoader.newest([(index: 1, revision: 4)]), 1)
        // One copy lags behind: the newer one is used, wherever it is listed.
        XCTAssertEqual(CatalogLoader.newest([(index: 0, revision: 3), (index: 1, revision: 4)]), 1)
        XCTAssertEqual(CatalogLoader.newest([(index: 1, revision: 3), (index: 0, revision: 4)]), 0)
        // Same revision: the address listed first, whichever answered first.
        XCTAssertEqual(CatalogLoader.newest([(index: 1, revision: 4), (index: 0, revision: 4)]), 0)
    }

    func testDefaultAddressesAreGitHubAndItsMirrors() {
        let urls = MoreAppsDefaults.catalogURLs
        XCTAssertEqual(urls.map(\.host), ["raw.githubusercontent.com", "cdn.jsdelivr.net",
                                          "fastly.jsdelivr.net", "gcore.jsdelivr.net"])
        XCTAssertTrue(urls.allSatisfy { $0.scheme == "https" && $0.lastPathComponent == "apps.json" })
    }

    // MARK: Decoding rules

    func testGitHubLinkIsKeptOnlyWhenItPointsAtGitHub() throws {
        let dmg = #"{"kind":"dmg","url":"https://example.com/a.dmg"}"#
        let decoded = try catalog("""
        {"schema":1,"revision":1,"apps":[
          \(app(id: "open", install: dmg, extra: #""github":"https://github.com/example/open","#)),
          \(app(id: "closed", install: dmg)),
          \(app(id: "elsewhere", install: dmg, extra: #""github":"https://example.com/example/open","#)),
          \(app(id: "plain", install: dmg, extra: #""github":"http://github.com/example/open","#)),
          \(app(id: "root", install: dmg, extra: #""github":"https://github.com/","#)),
          \(app(id: "number", install: dmg, extra: #""github":7,"#))
        ]}
        """)
        // A bad link costs the app its GitHub mark, never its place in the list.
        XCTAssertEqual(decoded.apps.map(\.id), ["open", "closed", "elsewhere", "plain", "root", "number"])
        XCTAssertEqual(decoded.apps[0].github?.absoluteString, "https://github.com/example/open")
        XCTAssertEqual(decoded.apps.dropFirst().compactMap(\.github), [])
    }

    func testBundledAppsLinkToTheirRepositoriesExceptTheOneThatIsNotOpenSource() {
        for app in MoreAppsCatalog.bundled().apps {
            if app.id == "pastepaw" {
                // Its repository holds only the Windows version; the macOS app
                // is not open source, so it gets no GitHub mark.
                XCTAssertNil(app.github)
                continue
            }
            XCTAssertEqual(app.github?.host, "github.com", "\(app.id) has no GitHub link")
            XCTAssertEqual(app.github?.pathComponents.count, 3, "\(app.id): expected /owner/repository")
        }
    }

    func testDecodesTheThreeInstallShapes() throws {
        let decoded = try catalog("""
        {"schema":1,"revision":7,"apps":[
          \(app(id: "one", install: #"{"kind":"dmg","url":"https://example.com/one.dmg"}"#)),
          \(app(id: "two", install: #"{"kind":"dmg","urls":{"arm64":"https://example.com/a.dmg","x86_64":"https://example.com/x.dmg"}}"#)),
          \(app(id: "three", install: #"{"kind":"appStore","url":"https://apps.apple.com/app/id1"}"#))
        ]}
        """)
        XCTAssertEqual(decoded.revision, 7)
        XCTAssertEqual(decoded.apps[0].diskImageURL(for: .arm64)?.lastPathComponent, "one.dmg")
        XCTAssertEqual(decoded.apps[0].diskImageURL(for: .x86_64)?.lastPathComponent, "one.dmg")
        XCTAssertEqual(decoded.apps[1].diskImageURL(for: .arm64)?.lastPathComponent, "a.dmg")
        XCTAssertEqual(decoded.apps[1].diskImageURL(for: .x86_64)?.lastPathComponent, "x.dmg")
        XCTAssertTrue(decoded.apps[2].isAppStore)
        XCTAssertNil(decoded.apps[2].diskImageURL(for: .arm64))
    }

    func testOneBrokenAppDoesNotLoseTheRest() throws {
        let decoded = try catalog("""
        {"schema":1,"apps":[
          \(app(id: "good", install: #"{"kind":"dmg","url":"https://example.com/good.dmg"}"#)),
          \(app(id: "future", install: #"{"kind":"somethingNew","url":"https://example.com/x"}"#)),
          \(app(id: "plain-http", install: #"{"kind":"dmg","url":"http://example.com/x.dmg"}"#)),
          \(app(id: "Bad_ID", install: #"{"kind":"dmg","url":"https://example.com/x.dmg"}"#)),
          \(app(id: "good", install: #"{"kind":"dmg","url":"https://example.com/duplicate.dmg"}"#))
        ]}
        """)
        XCTAssertEqual(decoded.apps.map(\.id), ["good"])
        XCTAssertEqual(decoded.apps[0].diskImageURL(for: .arm64)?.lastPathComponent, "good.dmg")
        XCTAssertEqual(decoded.revision, 0)
    }

    func testRejectsANewerSchemaAndAnEmptyList() {
        XCTAssertThrowsError(try catalog(#"{"schema":2,"apps":[]}"#)) {
            XCTAssertEqual($0 as? MoreAppsCatalog.CatalogError, .unsupportedSchema(2))
        }
        XCTAssertThrowsError(try catalog(#"{"schema":1,"apps":[]}"#)) {
            XCTAssertEqual($0 as? MoreAppsCatalog.CatalogError, .empty)
        }
    }

    func testAppBuiltForOneProcessorOnlyHasNoDownloadForTheOther() throws {
        let decoded = try catalog("""
        {"schema":1,"apps":[\(app(install: #"{"kind":"dmg","urls":{"arm64":"https://example.com/a.dmg"}}"#))]}
        """)
        XCTAssertNotNil(decoded.apps[0].diskImageURL(for: .arm64))
        XCTAssertNil(decoded.apps[0].diskImageURL(for: .x86_64))
    }

    // MARK: Taglines and versions

    func testTaglineFallsBackFromRegionToLanguageToEnglish() throws {
        let decoded = try catalog("""
        {"schema":1,"apps":[\(app(install: #"{"kind":"dmg","url":"https://example.com/a.dmg"}"#))]}
        """)
        let demo = decoded.apps[0]
        XCTAssertEqual(demo.tagline(forLanguage: "zh-Hans"), "中文")
        XCTAssertEqual(demo.tagline(forLanguage: "zh-hans"), "中文")   // SwiftPM's spelling
        XCTAssertEqual(demo.tagline(forLanguage: "zh-Hant"), "中文")   // nearest Chinese
        XCTAssertEqual(demo.tagline(forLanguage: "zh"), "中文")
        XCTAssertEqual(demo.tagline(forLanguage: "en-GB"), "English")
        XCTAssertEqual(demo.tagline(forLanguage: "fr"), "English")
    }

    func testMinimumSystemVersion() {
        func supported(_ minOS: String?, on version: (Int, Int, Int)) -> Bool {
            MoreApp(id: "demo", name: "Demo", bundleID: "com.example.demo", tagline: [:], minOS: minOS,
                    install: .appStore(URL(string: "https://apps.apple.com/app/id1")!))
                .isSupported(on: OperatingSystemVersion(majorVersion: version.0, minorVersion: version.1,
                                                        patchVersion: version.2))
        }
        XCTAssertTrue(supported("14.0", on: (14, 0, 0)))
        XCTAssertTrue(supported("14.0", on: (15, 1, 0)))
        XCTAssertFalse(supported("14.0", on: (13, 6, 4)))
        XCTAssertTrue(supported("13.3", on: (13, 3, 1)))
        XCTAssertFalse(supported("13.3", on: (13, 2, 9)))
        XCTAssertTrue(supported("10.13", on: (13, 0, 0)))
        XCTAssertTrue(supported(nil, on: (13, 0, 0)))
        XCTAssertTrue(supported("not a version", on: (13, 0, 0)))   // unreadable: do not block
    }
}

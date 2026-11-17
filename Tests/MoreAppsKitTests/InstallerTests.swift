import AppKit
import XCTest
@testable import MoreAppsKit

// These tests run the real installer against real released disk images, but
// install into a temporary folder, never into /Applications.
//
// They need the network and one of the author's signed apps on this Mac (to
// learn the signing team), so they only run when asked:
//
//   MOREAPPS_NETWORK_TESTS=1 swift test                  one small app, every code path
//   MOREAPPS_NETWORK_TESTS=all swift test                additionally every app in the catalog

final class InstallerTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoreAppsKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.path)
        try? FileManager.default.removeItem(at: scratch)
    }

    private var mode: String? { ProcessInfo.processInfo.environment["MOREAPPS_NETWORK_TESTS"] }

    /// The team that signed the author's apps, read from one that is installed.
    private func referenceTeam() throws -> String {
        try XCTSkipIf(mode == nil, "set MOREAPPS_NETWORK_TESTS=1 to run the installer tests")
        for app in MoreAppsCatalog.bundled().apps where !app.isAppStore {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID),
               url.path.hasPrefix("/Applications/"),
               let team = CodeSignature.teamIdentifier(ofBundleAt: url) {
                return team
            }
        }
        throw XCTSkip("none of the catalog's apps is installed in /Applications to read the signing team from")
    }

    private func catalogApp(_ id: String) throws -> MoreApp {
        try XCTUnwrap(MoreAppsCatalog.bundled().apps.first { $0.id == id })
    }

    private func makeInstaller(applications name: String = "Applications") throws -> AppInstaller {
        var installer = AppInstaller()
        installer.applicationsDirectory = scratch.appendingPathComponent(name, isDirectory: true)
        installer.downloadsDirectory = scratch.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: installer.applicationsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installer.downloadsDirectory, withIntermediateDirectories: true)
        return installer
    }

    private func leftoverWorkFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix("MoreAppsKit-") }
    }

    // MARK: The whole path

    func testDownloadVerifyAndInstallThenRefuseToOverwrite() async throws {
        let team = try referenceTeam()
        let app = try catalogApp("anydrag")
        let url = try XCTUnwrap(app.diskImageURL(for: .current))
        let installer = try makeInstaller()
        let before = Set(leftoverWorkFolders())

        final class Progress: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Double] = []
            func add(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
            var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let progress = Progress()
        let download = try await installer.download(url) { progress.add($0) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.diskImage.path))
        XCTAssertEqual(progress.all.last, 1)
        XCTAssertEqual(progress.all, progress.all.sorted(), "progress must never go backwards")

        let outcome = try await installer.install(app, from: download, teamID: team)
        let installed = installer.applicationsDirectory.appendingPathComponent("AnyDrag.app")
        XCTAssertEqual(outcome, .installed(installed))
        XCTAssertEqual(Bundle(url: installed)?.bundleIdentifier, app.bundleID)
        XCTAssertNoThrow(try CodeSignature.verify(appAt: installed, signedByTeam: team))
        XCTAssertEqual(Set(leftoverWorkFolders()), before, "the download folder must be cleaned up")

        // A second install finds the app there and leaves it alone.
        let marker = installed.appendingPathComponent("Contents/marker-from-test")
        try Data("x".utf8).write(to: marker)
        let again = try await installer.install(app, from: try await installer.download(url) { _ in }, teamID: team)
        XCTAssertEqual(again, .alreadyPresent(installed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the existing app must not be replaced")
        XCTAssertEqual(Set(leftoverWorkFolders()), before)
    }

    func testAppSignedByAnotherTeamIsRejectedAndNothingIsCopied() async throws {
        _ = try referenceTeam()
        let app = try catalogApp("anydrag")
        let installer = try makeInstaller()
        let download = try await installer.download(try XCTUnwrap(app.diskImageURL(for: .current))) { _ in }
        do {
            _ = try await installer.install(app, from: download, teamID: "ABCDE12345")
            XCTFail("an app signed by a different team must not install")
        } catch let error as MoreAppsInstallError {
            XCTAssertEqual(error, MoreAppsInstallError(stage: .verify, reason: "signature"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installer.applicationsDirectory.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.workDirectory.path))
    }

    func testDiskImageHoldingADifferentAppIsRejected() async throws {
        let team = try referenceTeam()
        let anydrag = try catalogApp("anydrag")
        let installer = try makeInstaller()
        let download = try await installer.download(try XCTUnwrap(anydrag.diskImageURL(for: .current))) { _ in }
        // The catalog promised QDuo, but the image contains AnyDrag.
        do {
            _ = try await installer.install(try catalogApp("qduo"), from: download, teamID: team)
            XCTFail("the wrong app must not install")
        } catch let error as MoreAppsInstallError {
            XCTAssertEqual(error, MoreAppsInstallError(stage: .verify, reason: "bundle_id_mismatch"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installer.applicationsDirectory.path), [])
    }

    func testReadOnlyApplicationsFolderHandsOverTheDiskImage() async throws {
        let team = try referenceTeam()
        let app = try catalogApp("anydrag")
        let installer = try makeInstaller()
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: installer.applicationsDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: installer.applicationsDirectory.path)
        }
        let download = try await installer.download(try XCTUnwrap(app.diskImageURL(for: .current))) { _ in }
        let outcome = try await installer.install(app, from: download, teamID: team)
        let handed = installer.downloadsDirectory.appendingPathComponent("AnyDrag.dmg")
        XCTAssertEqual(outcome, .needsManualInstall(diskImage: handed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: handed.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installer.applicationsDirectory.path), [])
    }

    func testMissingFileReportsTheHTTPStatus() async throws {
        _ = try referenceTeam()
        let installer = try makeInstaller()
        let before = Set(leftoverWorkFolders())
        do {
            _ = try await installer.download(URL(string: "https://github.com/this-file-does-not-exist-moreappskit.dmg")!) { _ in }
            XCTFail("a missing file must fail")
        } catch let error as MoreAppsInstallError {
            XCTAssertEqual(error, MoreAppsInstallError(stage: .download, reason: "http_404"))
        }
        XCTAssertEqual(Set(leftoverWorkFolders()), before)
    }

    func testCancellingADownloadThrowsAndCleansUp() async throws {
        _ = try referenceTeam()
        let app = try catalogApp("attache")   // the largest image, so there is time to cancel
        let url = try XCTUnwrap(app.diskImageURL(for: .current))
        let installer = try makeInstaller()
        let before = Set(leftoverWorkFolders())
        let task = Task { try await installer.download(url) { _ in } }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            let download = try await task.value
            installer.discard(download)   // the network was faster than the cancel
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertEqual(Set(leftoverWorkFolders()), before)
    }

    // MARK: Every app in the catalog

    func testEveryCatalogDiskImageInstalls() async throws {
        let team = try referenceTeam()
        try XCTSkipIf(mode != "all", "set MOREAPPS_NETWORK_TESTS=all to download every app")
        for architecture in [MoreAppsArchitecture.arm64, .x86_64] {
            let installer = try makeInstaller(applications: "Applications-\(architecture.rawValue)")
            var seen = Set<URL>()
            for app in MoreAppsCatalog.bundled().apps where !app.isAppStore {
                let url = try XCTUnwrap(app.diskImageURL(for: architecture), app.id)
                // A universal image is the same file for both processors.
                guard architecture == .arm64 || app.diskImageURL(for: .arm64) != url else { continue }
                guard seen.insert(url).inserted else { continue }
                do {
                    let download = try await installer.download(url) { _ in }
                    let outcome = try await installer.install(app, from: download, teamID: team)
                    guard case .installed(let location) = outcome else {
                        XCTFail("\(app.id) (\(architecture.rawValue)): unexpected outcome \(outcome)")
                        continue
                    }
                    XCTAssertEqual(Bundle(url: location)?.bundleIdentifier, app.bundleID, app.id)
                } catch {
                    XCTFail("\(app.id) (\(architecture.rawValue)) failed: \(error)")
                }
            }
        }
    }
}

final class CodeSignatureTests: XCTestCase {

    func testTeamIdentifierShape() {
        XCTAssertTrue(CodeSignature.isValidTeamIdentifier("ABCDE12345"))
        XCTAssertFalse(CodeSignature.isValidTeamIdentifier("ABCDE1234"))
        XCTAssertFalse(CodeSignature.isValidTeamIdentifier("abcde12345"))
        XCTAssertFalse(CodeSignature.isValidTeamIdentifier("ABCDE1234\""))
        XCTAssertFalse(CodeSignature.isValidTeamIdentifier("AB\" or true"))
    }

    func testMalformedTeamNeverReachesTheRequirement() {
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        XCTAssertThrowsError(try CodeSignature.verify(appAt: safari, signedByTeam: "X\" or anchor apple or \"")) {
            XCTAssertEqual(($0 as? CodeSignature.VerificationError)?.detail, "malformed team identifier")
        }
    }

    func testAppleSystemAppDoesNotPassAsADeveloperIDApp() {
        // Safari is validly signed, but by Apple, not by a Developer ID team.
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        XCTAssertThrowsError(try CodeSignature.verify(appAt: safari, signedByTeam: "ABCDE12345"))
        XCTAssertNil(CodeSignature.teamIdentifier(ofBundleAt: URL(fileURLWithPath: "/nonexistent.app")))
    }

    func testAFolderThatIsNotAnAppIsRejected() {
        XCTAssertThrowsError(try CodeSignature.verify(appAt: FileManager.default.temporaryDirectory,
                                                      signedByTeam: "ABCDE12345"))
    }
}

/// The parts of the installer that can be checked without a network or a
/// signed app: picking the app out of a mounted image, and naming a hand-over
/// file.
final class InstallerOfflineTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoreAppsKitOffline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func makeApp(_ name: String, bundleID: String, in parent: URL? = nil) throws -> URL {
        let app = (parent ?? folder).appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    func testPicksTheAppWithTheExpectedBundleID() throws {
        try makeApp("Other", bundleID: "com.example.other")
        let wanted = try makeApp("Wanted", bundleID: "com.example.wanted")
        let found = try AppInstaller.findApp(in: folder, bundleID: "com.example.wanted")
        XCTAssertEqual(found.standardizedFileURL, wanted.standardizedFileURL)
    }

    func testImageWithoutTheExpectedAppIsRejected() throws {
        try makeApp("Other", bundleID: "com.example.other")
        XCTAssertThrowsError(try AppInstaller.findApp(in: folder, bundleID: "com.example.wanted")) {
            XCTAssertEqual($0 as? MoreAppsInstallError, .init(stage: .verify, reason: "bundle_id_mismatch"))
        }
    }

    func testImageWithNoAppAtAllIsRejected() throws {
        try Data("x".utf8).write(to: folder.appendingPathComponent("README.txt"))
        XCTAssertThrowsError(try AppInstaller.findApp(in: folder, bundleID: "com.example.wanted")) {
            XCTAssertEqual($0 as? MoreAppsInstallError, .init(stage: .mount, reason: "no_app"))
        }
    }

    func testSymbolicLinkNamedLikeAnAppDoesNotCount() throws {
        // The real bundle lives outside the "image"; the image only holds a link to it.
        let outside = folder.appendingPathComponent("outside", isDirectory: true)
        let image = folder.appendingPathComponent("image", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        let real = try makeApp("Wanted", bundleID: "com.example.wanted", in: outside)
        try FileManager.default.createSymbolicLink(at: image.appendingPathComponent("Wanted.app"),
                                                   withDestinationURL: real)
        XCTAssertThrowsError(try AppInstaller.findApp(in: image, bundleID: "com.example.wanted")) {
            XCTAssertEqual($0 as? MoreAppsInstallError, .init(stage: .mount, reason: "no_app"))
        }
    }

    func testHandOverFileGetsAFreshNameWhenTheNameIsTaken() throws {
        XCTAssertEqual(AppInstaller.uniqueURL(in: folder, name: "App", ext: "dmg").lastPathComponent, "App.dmg")
        try Data().write(to: folder.appendingPathComponent("App.dmg"))
        XCTAssertEqual(AppInstaller.uniqueURL(in: folder, name: "App", ext: "dmg").lastPathComponent, "App 2.dmg")
        try Data().write(to: folder.appendingPathComponent("App 2.dmg"))
        XCTAssertEqual(AppInstaller.uniqueURL(in: folder, name: "App", ext: "dmg").lastPathComponent, "App 3.dmg")
    }
}

import Foundation

// Downloads an app's disk image and puts the app into the Applications folder.
//
//   download the disk image into a private temporary folder
//   mount it without showing it in Finder
//   find the .app whose bundle id is the one the catalog promised
//   check its code signature (see CodeSignature)
//   if the Applications folder is not writable (a non-admin account):
//       hand the disk image to the user in ~/Downloads instead
//   copy the app next to its destination, check the copy's signature again,
//   then move it into place in one step
//   unmount and delete the temporary files
//
// An app that already exists at the destination is never overwritten: updating
// an installed app is that app's own job.

/// Why an install stopped. `stage` and `reason` are short machine-readable
/// codes; they are also what the analytics events report.
public struct MoreAppsInstallError: Error, Equatable {
    public enum Stage: String, Equatable {
        case download, mount, verify, copy
    }
    public let stage: Stage
    public let reason: String

    public init(stage: Stage, reason: String) {
        self.stage = stage
        self.reason = reason
    }
}

struct AppInstaller {

    enum Outcome: Equatable {
        /// The app was copied into the Applications folder.
        case installed(URL)
        /// An app with the same bundle id was already at the destination; it was
        /// left untouched.
        case alreadyPresent(URL)
        /// The Applications folder is not writable. The verified disk image was
        /// moved to this location for the user to open.
        case needsManualInstall(diskImage: URL)
    }

    var applicationsDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)
    var downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory

    /// A downloaded disk image plus the private folder it lives in.
    struct Download {
        let workDirectory: URL
        let diskImage: URL
    }

    // MARK: Download

    /// Downloads `url` into a fresh temporary folder. `progress` receives values
    /// from 0 to 1 on an arbitrary thread. Cancelling the surrounding task
    /// cancels the transfer and throws `CancellationError`.
    func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Download {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MoreAppsKit-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw MoreAppsInstallError(stage: .download, reason: "temp_dir")
        }
        let image = work.appendingPathComponent("download.dmg")
        do {
            try await FileDownloader(destination: image, progress: progress).run(from: url)
        } catch {
            try? fm.removeItem(at: work)
            if error is CancellationError { throw error }
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            if let known = error as? MoreAppsInstallError { throw known }
            let code = (error as? URLError).map { "url_\($0.code.rawValue)" } ?? "network"
            throw MoreAppsInstallError(stage: .download, reason: code)
        }
        return Download(workDirectory: work, diskImage: image)
    }

    /// Deletes a download that will not be installed (the user cancelled).
    func discard(_ download: Download) {
        try? FileManager.default.removeItem(at: download.workDirectory)
    }

    // MARK: Install

    /// Installs `app` from a finished download. Always cleans up the download.
    func install(_ app: MoreApp, from download: Download, teamID: String) async throws -> Outcome {
        let fm = FileManager.default
        let mountRoot = download.workDirectory.appendingPathComponent("mount", isDirectory: true)
        var mountPoint: URL?
        var keepDiskImage = false
        // False once an unmount has failed: a volume is then still mounted
        // inside the work folder, and the folder must not be deleted recursively.
        var unmounted = true

        do {
            try fm.createDirectory(at: mountRoot, withIntermediateDirectories: true)
            let mounted = try await Self.attach(download.diskImage, under: mountRoot)
            mountPoint = mounted

            let source = try Self.findApp(in: mounted, bundleID: app.bundleID)
            do {
                try CodeSignature.verify(appAt: source, signedByTeam: teamID)
            } catch {
                throw MoreAppsInstallError(stage: .verify, reason: "signature")
            }

            let destination = applicationsDirectory.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            let outcome: Outcome
            if fm.fileExists(atPath: destination.path) {
                guard Bundle(url: destination)?.bundleIdentifier == app.bundleID else {
                    throw MoreAppsInstallError(stage: .copy, reason: "destination_taken")
                }
                outcome = .alreadyPresent(destination)
            } else if !fm.isWritableFile(atPath: applicationsDirectory.path) {
                let handoff = Self.uniqueURL(in: downloadsDirectory,
                                             name: source.deletingPathExtension().lastPathComponent, ext: "dmg")
                unmounted = await Self.detach(mounted)
                mountPoint = nil
                do {
                    try fm.moveItem(at: download.diskImage, to: handoff)
                } catch {
                    throw MoreAppsInstallError(stage: .copy, reason: "applications_not_writable")
                }
                keepDiskImage = true
                outcome = .needsManualInstall(diskImage: handoff)
            } else {
                try Self.copyVerified(source, to: destination, teamID: teamID, near: applicationsDirectory)
                outcome = .installed(destination)
            }

            if let mountPoint { unmounted = await Self.detach(mountPoint) }
            Self.cleanUp(download, keepDiskImage: keepDiskImage, unmounted: unmounted && Self.isEmpty(mountRoot))
            return outcome
        } catch {
            if let mountPoint { unmounted = await Self.detach(mountPoint) }
            Self.cleanUp(download, keepDiskImage: false, unmounted: unmounted && Self.isEmpty(mountRoot))
            if let known = error as? MoreAppsInstallError { throw known }
            if error is CancellationError { throw error }
            throw MoreAppsInstallError(stage: .copy, reason: "unexpected")
        }
    }

    /// Copies `source` into a staging folder on the destination's volume,
    /// verifies the copy (so what gets installed is exactly what was checked),
    /// then renames it into place.
    private static func copyVerified(_ source: URL, to destination: URL, teamID: String, near directory: URL) throws {
        let fm = FileManager.default
        let staging: URL
        do {
            staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: directory, create: true)
        } catch {
            throw MoreAppsInstallError(stage: .copy, reason: "staging")
        }
        defer { try? fm.removeItem(at: staging) }

        let staged = staging.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        do {
            try fm.copyItem(at: source, to: staged)
        } catch {
            throw MoreAppsInstallError(stage: .copy, reason: "copy")
        }
        do {
            try CodeSignature.verify(appAt: staged, signedByTeam: teamID)
        } catch {
            throw MoreAppsInstallError(stage: .verify, reason: "signature_after_copy")
        }
        do {
            try fm.moveItem(at: staged, to: destination)
        } catch {
            throw MoreAppsInstallError(stage: .copy, reason: "move")
        }
    }

    /// The real app bundle at the top level of the mounted image whose bundle id
    /// is the expected one. A symbolic link named `Something.app` does not count.
    static func findApp(in mountPoint: URL, bundleID: String) throws -> URL {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? fm.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles]) else {
            throw MoreAppsInstallError(stage: .mount, reason: "unreadable")
        }
        let apps = entries.filter { url in
            guard url.pathExtension.lowercased() == "app",
                  let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        guard !apps.isEmpty else { throw MoreAppsInstallError(stage: .mount, reason: "no_app") }
        guard let match = apps.first(where: { Bundle(url: $0)?.bundleIdentifier == bundleID }) else {
            throw MoreAppsInstallError(stage: .verify, reason: "bundle_id_mismatch")
        }
        return match
    }

    /// True when no volume is left mounted under `mountRoot`. hdiutil removes a
    /// mount folder when it unmounts, so anything still there is a live volume
    /// (an image with several partitions, or an unmount that did not finish).
    private static func isEmpty(_ mountRoot: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: mountRoot.path)) ?? []).isEmpty
    }

    private static func cleanUp(_ download: Download, keepDiskImage: Bool, unmounted: Bool) {
        let fm = FileManager.default
        if unmounted {
            // Safe to remove everything: nothing is mounted inside any more.
            try? fm.removeItem(at: download.workDirectory)
        } else if !keepDiskImage {
            // A volume is still mounted under the work folder. Do not walk into
            // it; just drop the image file. macOS clears the temp folder later.
            try? fm.removeItem(at: download.diskImage)
        }
    }

    static func uniqueURL(in directory: URL, name: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: hdiutil

    /// Mounts the image read-only at a random folder under `root`, hidden from
    /// Finder, and returns the mount point.
    static func attach(_ image: URL, under root: URL) async throws -> URL {
        let result = await runTool("/usr/bin/hdiutil", [
            "attach", "-plist", "-nobrowse", "-readonly", "-noautoopen",
            "-mountrandom", root.path, image.path,
        ])
        guard result.status == 0 else {
            throw MoreAppsInstallError(stage: .mount, reason: "attach_\(result.status)")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: result.output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let path = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw MoreAppsInstallError(stage: .mount, reason: "no_mount_point")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    @discardableResult
    static func detach(_ mountPoint: URL) async -> Bool {
        await runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]).status == 0
    }

    /// Runs a system tool off the calling thread and returns its exit status and
    /// standard output. Standard input is closed so a tool can never sit
    /// waiting for an answer (hdiutil would, on an image with a license text).
    private static func runTool(_ path: String, _ arguments: [String]) async -> (status: Int32, output: Data) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, Data()))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, data))
            }
        }
    }
}

// MARK: - Download with progress

/// One file download with progress reporting and task cancellation.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var failure: Error?
    private var lastReported = -1.0

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run(from url: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let task = session.downloadTask(with: url)
                self.task = task
                // Started while the lock is held: `onCancel` takes the same
                // lock, so it can only ever cancel a task that is running.
                task.resume()
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        lock.lock()
        // Report in whole-percent steps; the callback fires far more often.
        let changed = fraction - lastReported >= 0.01 || fraction == 1
        if changed { lastReported = fraction }
        lock.unlock()
        if changed { progress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so it has to
        // be moved now.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        var problem: Error?
        if status != 200 {
            problem = MoreAppsInstallError(stage: .download, reason: "http_\(status)")
        } else {
            do {
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                problem = MoreAppsInstallError(stage: .download, reason: "save")
            }
        }
        lock.lock()
        failure = problem
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure = error ?? self.failure
        let wasCancelled = cancelled
        lock.unlock()

        if wasCancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let failure {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }
}

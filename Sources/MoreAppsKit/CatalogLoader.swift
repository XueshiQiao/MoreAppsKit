import AppKit
import Foundation

// Keeps the catalog and the app icons up to date from the network, with a disk
// cache so a fetched copy survives relaunches.
//
// Everything fetched is treated as untrusted input: it is size-limited, has to
// decode cleanly, and can only ever change what the page lists. It cannot
// weaken the install check, which depends solely on the code signature.

final class CatalogLoader {

    private let urls: [URL]
    private let cacheDirectory: URL
    private let session: URLSession

    private static let catalogFile = "apps.json"
    private static let sourceFile = "source.txt"
    private static let maxCatalogBytes = 512 * 1024
    private static let maxIconBytes = 1024 * 1024

    init(urls: [URL], hostBundleID: String) {
        self.urls = urls
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let host = hostBundleID.isEmpty ? "unknown-host" : hostBundleID
        cacheDirectory = caches.appendingPathComponent(host, isDirectory: true)
            .appendingPathComponent("MoreAppsKit", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    /// A catalog plus the URL it was fetched from (relative icon paths resolve
    /// against it).
    struct Loaded {
        let catalog: MoreAppsCatalog
        let source: URL?
    }

    // MARK: Catalog

    /// The copy saved by the last successful fetch, if it still decodes.
    func cached() -> Loaded? {
        let file = cacheDirectory.appendingPathComponent(Self.catalogFile)
        guard let data = try? Data(contentsOf: file), let catalog = try? MoreAppsCatalog.decode(data) else { return nil }
        let source = (try? String(contentsOf: cacheDirectory.appendingPathComponent(Self.sourceFile), encoding: .utf8))
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return Loaded(catalog: catalog, source: source)
    }

    /// Tries each catalog URL in order and returns the first one that answers
    /// with a valid catalog, saving it to the cache.
    func fetch() async -> Loaded? {
        for url in urls {
            guard let data = await get(url, limit: Self.maxCatalogBytes),
                  let catalog = try? MoreAppsCatalog.decode(data) else { continue }
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: cacheDirectory.appendingPathComponent(Self.catalogFile), options: .atomic)
            try? url.absoluteString.write(to: cacheDirectory.appendingPathComponent(Self.sourceFile),
                                          atomically: true, encoding: .utf8)
            return Loaded(catalog: catalog, source: url)
        }
        return nil
    }

    // MARK: Icons

    /// The icon shipped inside the package for a known app id.
    static func bundledIcon(for app: MoreApp) -> NSImage? {
        guard let url = Bundle.module.url(forResource: "moreapps-icon-\(app.id)", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    /// An icon downloaded earlier for an app that has none in the package.
    func cachedIcon(for app: MoreApp) -> NSImage? {
        NSImage(contentsOf: iconCacheURL(for: app))
    }

    /// Downloads the icon named by the catalog and saves it to the cache.
    func fetchIcon(for app: MoreApp, catalogSource: URL?) async -> NSImage? {
        guard let location = app.icon,
              let url = URL(string: location, relativeTo: catalogSource)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              let data = await get(url, limit: Self.maxIconBytes),
              let image = NSImage(data: data), image.isValid else { return nil }
        let file = iconCacheURL(for: app)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return image
    }

    private func iconCacheURL(for app: MoreApp) -> URL {
        // `app.id` is restricted to [a-z0-9-], so it is safe as a file name.
        cacheDirectory.appendingPathComponent("icons", isDirectory: true).appendingPathComponent("\(app.id).png")
    }

    // MARK: Network

    /// Fetches `url`, giving up as soon as the body grows past `limit` bytes,
    /// so a wrong or hostile server cannot make the app hold a huge response.
    private func get(_ url: URL, limit: Int) async -> Data? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (bytes, response) = try? await session.bytes(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= Int64(limit) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return nil }   // leaving the loop cancels the transfer
            }
        } catch {
            return nil
        }
        return data.isEmpty ? nil : data
    }
}

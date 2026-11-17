import Foundation

// The catalog is the list of apps shown on the "More Apps" page. One copy is
// bundled with the package (Resources/apps.json) so the page works offline and
// on first launch; a newer copy can be fetched from the network, so adding an
// app does not require every host app to ship an update.

/// The CPU kind of this Mac, used to pick the right disk image for apps that
/// ship one download per architecture.
public enum MoreAppsArchitecture: String, Equatable {
    case arm64
    case x86_64

    /// The hardware's architecture (not the running slice: an Intel build under
    /// Rosetta still reports `arm64`, because the installed app should be the
    /// native one).
    public static var current: MoreAppsArchitecture {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 {
            return .arm64
        }
        return .x86_64
    }
}

/// One app in the catalog.
public struct MoreApp: Decodable, Equatable, Identifiable {

    /// How the app gets onto the user's Mac.
    public enum Install: Equatable {
        /// A disk image to download. `universal` serves every Mac; otherwise the
        /// per-architecture URL is used.
        case diskImage(universal: URL?, arm64: URL?, x86_64: URL?)
        /// The app lives in the Mac App Store; the button opens its page.
        case appStore(URL)
    }

    /// Stable lowercase identifier (`qduo`). Used for icon file names and as the
    /// `target` property of analytics events.
    public let id: String
    public let name: String
    public let bundleID: String
    /// One-line description keyed by language code (`en`, `zh-Hans`).
    public let tagline: [String: String]
    public let homepage: URL?
    /// Lowest macOS version that can run the app, e.g. `14.0`.
    public let minOS: String?
    /// Icon location for apps whose icon is not bundled with the package:
    /// an absolute https URL, or a path relative to the catalog's own URL.
    public let icon: String?
    /// The app's public source repository on GitHub, for an open-source app.
    /// The page shows a GitHub mark next to the name that opens it.
    public let github: URL?
    public let install: Install

    public init(id: String, name: String, bundleID: String, tagline: [String: String],
                homepage: URL? = nil, minOS: String? = nil, icon: String? = nil, github: URL? = nil,
                install: Install) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.tagline = tagline
        self.homepage = homepage
        self.minOS = minOS
        self.icon = icon
        self.github = github
        self.install = install
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, bundleID = "bundleId", tagline, homepage, minOS, icon, github, install
    }
    private enum InstallKeys: String, CodingKey { case kind, url, urls }
    private enum ArchKeys: String, CodingKey { case arm64, x86_64 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        guard MoreApp.isValidID(id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "invalid app id")
        }
        name = try c.decode(String.self, forKey: .name)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        guard !name.isEmpty, !bundleID.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "empty name or bundle id")
        }
        tagline = try c.decodeIfPresent([String: String].self, forKey: .tagline) ?? [:]
        homepage = try MoreApp.httpsURL(c.decodeIfPresent(String.self, forKey: .homepage))
        minOS = try c.decodeIfPresent(String.self, forKey: .minOS)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        github = MoreApp.githubURL(try? c.decodeIfPresent(String.self, forKey: .github))

        let i = try c.nestedContainer(keyedBy: InstallKeys.self, forKey: .install)
        let kind = try i.decode(String.self, forKey: .kind)
        switch kind {
        case "dmg":
            let universal = try MoreApp.httpsURL(i.decodeIfPresent(String.self, forKey: .url))
            var arm: URL?
            var intel: URL?
            if i.contains(.urls) {
                let a = try i.nestedContainer(keyedBy: ArchKeys.self, forKey: .urls)
                arm = try MoreApp.httpsURL(a.decodeIfPresent(String.self, forKey: .arm64))
                intel = try MoreApp.httpsURL(a.decodeIfPresent(String.self, forKey: .x86_64))
            }
            guard universal != nil || arm != nil || intel != nil else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: i, debugDescription: "dmg install without a url")
            }
            install = .diskImage(universal: universal, arm64: arm, x86_64: intel)
        case "appStore":
            guard let url = try MoreApp.httpsURL(i.decode(String.self, forKey: .url)) else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: i, debugDescription: "appStore install without a url")
            }
            install = .appStore(url)
        default:
            // A kind this version does not know. Throwing makes the lossy catalog
            // decoder drop this one app and keep the rest.
            throw DecodingError.dataCorruptedError(forKey: .kind, in: i, debugDescription: "unknown install kind \(kind)")
        }
    }

    /// App ids end up in file names and analytics, so keep them boring.
    static func isValidID(_ id: String) -> Bool {
        guard (1...40).contains(id.count), let first = id.unicodeScalars.first else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return first != "-" && id.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// The link behind the GitHub mark: https, and on github.com itself, so
    /// the mark can never lead anywhere else. Anything else just means no mark;
    /// it does not cost the app its place in the list.
    private static func githubURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string),
              url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com",
              url.path.count > 1 else { return nil }
        return url
    }

    /// Only https links are accepted anywhere in the catalog. A missing value
    /// stays nil; a present but non-https value is an error.
    private static func httpsURL(_ string: String?) throws -> URL? {
        guard let string else { return nil }
        guard let url = URL(string: string), url.scheme?.lowercased() == "https", url.host != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an https url"))
        }
        return url
    }
}

public extension MoreApp {

    /// The tagline in `code` (`zh-Hans`), falling back to the bare language
    /// (`zh`), then English, then whatever exists.
    func tagline(forLanguage code: String) -> String {
        // Compare without regard to case: SwiftPM reports `zh-hans` where the
        // catalog says `zh-Hans`.
        let wanted = code.lowercased()
        let keys = tagline.keys.sorted()
        if let exact = keys.first(where: { $0.lowercased() == wanted }), let value = tagline[exact] {
            return value
        }
        let base = wanted.split(separator: "-").first.map(String.init) ?? wanted
        if let match = keys.first(where: { $0.lowercased() == base || $0.lowercased().hasPrefix(base + "-") }),
           let value = tagline[match] {
            return value
        }
        return tagline["en"] ?? keys.first.flatMap { tagline[$0] } ?? ""
    }

    /// The disk image to download on a Mac of the given architecture, or nil
    /// when the app is not a disk-image install or has no build for it.
    func diskImageURL(for architecture: MoreAppsArchitecture) -> URL? {
        guard case let .diskImage(universal, arm64, x86_64) = install else { return nil }
        switch architecture {
        case .arm64:  return arm64 ?? universal
        case .x86_64: return x86_64 ?? universal
        }
    }

    var isAppStore: Bool {
        if case .appStore = install { return true }
        return false
    }

    /// Whether `minOS` allows running on the given system version.
    func isSupported(on system: OperatingSystemVersion) -> Bool {
        guard let minOS, let required = MoreApp.parseVersion(minOS) else { return true }
        let have = [system.majorVersion, system.minorVersion, system.patchVersion]
        for (need, got) in zip(required, have) where need != got {
            return got > need
        }
        return true
    }

    /// `"14.2"` → `[14, 2, 0]`. Nil when the text is not a dotted number.
    internal static func parseVersion(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(where: { $0 == nil }) else { return nil }
        var numbers = parts.compactMap { $0 }
        while numbers.count < 3 { numbers.append(0) }
        return numbers
    }
}

/// The whole catalog file.
public struct MoreAppsCatalog: Decodable, Equatable {

    /// The file format this version of the package understands. A future,
    /// incompatible format must be published at a different URL so that older
    /// apps keep reading this one.
    public static let supportedSchema = 1

    public let schema: Int
    /// Increases every time the catalog is edited. Among the bundled, cached and
    /// freshly fetched copies, the one with the highest revision wins.
    public let revision: Int
    /// In display priority order.
    public let apps: [MoreApp]

    public init(schema: Int = MoreAppsCatalog.supportedSchema, revision: Int, apps: [MoreApp]) {
        self.schema = schema
        self.revision = revision
        self.apps = apps
    }

    private enum CodingKeys: String, CodingKey { case schema, revision, apps }

    /// Wraps an element so one malformed app does not fail the whole array.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        var seen = Set<String>()
        // Drop malformed apps and later duplicates of an id.
        apps = try c.decode([Lossy<MoreApp>].self, forKey: .apps)
            .compactMap(\.value)
            .filter { seen.insert($0.id).inserted }
    }

    public enum CatalogError: Error, Equatable {
        case unsupportedSchema(Int)
        case empty
    }

    /// Decode and sanity-check catalog data from any source.
    public static func decode(_ data: Data) throws -> MoreAppsCatalog {
        let catalog = try JSONDecoder().decode(MoreAppsCatalog.self, from: data)
        guard catalog.schema == supportedSchema else { throw CatalogError.unsupportedSchema(catalog.schema) }
        guard !catalog.apps.isEmpty else { throw CatalogError.empty }
        return catalog
    }

    /// The copy shipped inside the package. Always present; a broken bundle is a
    /// build error caught by the tests, so an empty catalog is the only sane
    /// runtime fallback.
    public static func bundled() -> MoreAppsCatalog {
        guard let url = Bundle.module.url(forResource: "apps", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? decode(data) else {
            return MoreAppsCatalog(revision: 0, apps: [])
        }
        return catalog
    }
}

extension Bundle {
    /// The package's resource bundle (catalog, icons, string tables), under a
    /// name the tests can reach.
    static var moreAppsKit: Bundle { .module }
}

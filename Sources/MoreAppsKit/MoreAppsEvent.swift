import Foundation

// Analytics. The package does not talk to any analytics service itself. It hands
// each event to the host app (`MoreAppsStore.onEvent`), and the host forwards it
// to whatever it already uses, through its own opt-out switch.
//
// Every host app reports the same event names and properties, so the numbers
// from different apps can be compared side by side.
//
// What the events contain: the catalog id of the promoted app the user acted on
// (`target`, e.g. "qduo"), and short fixed codes. They never contain anything
// about the user's other software, files or identity.

public struct MoreAppsEvent: Equatable {

    /// Where on the page the user clicked.
    public enum Placement: String, Equatable {
        case featured
        case list
    }

    /// The small marks shown after an app's name.
    public enum Badge: String, Equatable {
        /// The app's source is public: opens its GitHub repository.
        case github
        /// The app is on the Mac App Store: opens its store page.
        case appStore = "app_store"
    }

    public let name: String
    public let properties: [String: String]

    public init(name: String, properties: [String: String] = [:]) {
        self.name = name
        self.properties = properties
    }

    // The funnel, in order:
    //
    //   more_apps_viewed            the page was shown
    //   more_apps_get_clicked       the user asked for an app
    //   more_apps_install_succeeded the app is in the Applications folder
    //
    // and the ways out of it:
    //
    //   more_apps_install_cancelled the user stopped the download
    //   more_apps_install_failed    something went wrong (stage + reason)
    //   more_apps_manual_fallback   the user was sent to finish by hand

    /// The page appeared. `source` is how the user got there (`sidebar`,
    /// `about`, `menu`, or `window` when the host's window was reopened on
    /// this page); `apps` is how many apps the page listed.
    static func viewed(source: String, appCount: Int) -> MoreAppsEvent {
        MoreAppsEvent(name: "more_apps_viewed", properties: ["source": source, "apps": String(appCount)])
    }

    /// The user clicked Get (or App Store). `kind` is `dmg` or `app_store`.
    static func getClicked(_ app: MoreApp, placement: Placement) -> MoreAppsEvent {
        MoreAppsEvent(name: "more_apps_get_clicked", properties: [
            "target": app.id,
            "kind": app.isAppStore ? "app_store" : "dmg",
            "placement": placement.rawValue,
        ])
    }

    /// The app was installed and launched. `seconds` is the whole duration from
    /// the click, rounded.
    static func installSucceeded(_ app: MoreApp, seconds: Int) -> MoreAppsEvent {
        MoreAppsEvent(name: "more_apps_install_succeeded", properties: ["target": app.id, "seconds": String(seconds)])
    }

    static func installFailed(_ app: MoreApp, error: MoreAppsInstallError) -> MoreAppsEvent {
        MoreAppsEvent(name: "more_apps_install_failed", properties: [
            "target": app.id,
            "stage": error.stage.rawValue,
            "reason": error.reason,
        ])
    }

    static func installCancelled(_ app: MoreApp) -> MoreAppsEvent {
        MoreAppsEvent(name: "more_apps_install_cancelled", properties: ["target": app.id])
    }

    /// The install could not be done for the user, who was handed either the
    /// disk image (`via: disk_image`) or a browser download (`via: browser`).
    static func manualFallback(_ app: MoreApp, via: String) -> MoreAppsEvent {
        MoreAppsEvent(name: "more_apps_manual_fallback", properties: ["target": app.id, "via": via])
    }

    /// The user opened an app that was already installed.
    static func openClicked(_ app: MoreApp) -> MoreAppsEvent {
        MoreAppsEvent(name: "more_apps_open_clicked", properties: ["target": app.id])
    }

    static func homepageClicked(_ app: MoreApp) -> MoreAppsEvent {
        MoreAppsEvent(name: "more_apps_homepage_clicked", properties: ["target": app.id])
    }

    /// A mark after the app's name was clicked. `badge` is `github` or
    /// `app_store`.
    static func badgeClicked(_ app: MoreApp, badge: Badge) -> MoreAppsEvent {
        MoreAppsEvent(name: "more_apps_badge_clicked", properties: ["target": app.id, "badge": badge.rawValue])
    }

    /// The list of apps was looked for on the network (at most once every 6
    /// hours, when the page is opened). Says which of the published addresses
    /// answered, so the author can see which hosts work from where:
    ///
    ///   used      the address whose answer was taken, or `none`
    ///   revision  the revision of that answer (absent when `used` is `none`)
    ///   <label>   one property per address asked: `ok` or `failed`
    ///
    /// For example `used: github, revision: 3, github: ok, jsdelivr: ok,
    /// jsdelivr_fastly: failed, jsdelivr_gcore: ok`.
    static func catalogFetched(_ report: CatalogLoader.FetchReport) -> MoreAppsEvent {
        var properties: [String: String] = [:]
        for outcome in report.outcomes {
            properties[sourceLabel(for: outcome.url)] = outcome.answered ? "ok" : "failed"
        }
        // Set last, so an address can never overwrite them.
        properties["used"] = report.loaded?.source.map(sourceLabel(for:)) ?? "none"
        if let loaded = report.loaded { properties["revision"] = String(loaded.catalog.revision) }
        return MoreAppsEvent(name: "more_apps_catalog_fetched", properties: properties)
    }

    /// A short, stable name for a catalog address, used as a property name and
    /// value in `more_apps_catalog_fetched`. The hosts the package uses by
    /// default have fixed names; any other host is spelled out with `_` for
    /// every character that is not a letter or digit.
    static func sourceLabel(for url: URL) -> String {
        let host = (url.host ?? "unknown").lowercased()
        switch host {
        case "raw.githubusercontent.com": return "github"
        case "cdn.jsdelivr.net":          return "jsdelivr"
        case "fastly.jsdelivr.net":       return "jsdelivr_fastly"
        case "gcore.jsdelivr.net":        return "jsdelivr_gcore"
        default:
            return String(host.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
        }
    }

    /// For the app on the receiving end: this launch was started by another
    /// app's More Apps page right after installing. `source` is that app's id.
    public static func referredLaunch(source: String) -> MoreAppsEvent {
        MoreAppsEvent(name: "more_apps_referred_launch", properties: ["source": source])
    }
}

public enum MoreApps {

    /// Name of the environment variable set on an app that is launched right
    /// after being installed from another app's More Apps page.
    static let referrerEnvironmentKey = "MOREAPPS_REFERRER"

    /// When this process was launched by another app's More Apps page, that
    /// app's catalog id (`anydrag`). Nil on every ordinary launch.
    ///
    /// A host app reads this once at startup and reports
    /// `MoreAppsEvent.referredLaunch(source:)`, which tells the installed app's
    /// own dashboard which sibling app sent the user.
    public static var launchReferrer: String? {
        guard let value = ProcessInfo.processInfo.environment[referrerEnvironmentKey],
              MoreApp.isValidID(value) else { return nil }
        return value
    }
}

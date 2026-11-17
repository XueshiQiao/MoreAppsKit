import Foundation

/// The author-specific addresses the package uses unless a host overrides them
/// in `MoreAppsStore.Configuration`.
public enum MoreAppsDefaults {

    /// Where a newer catalog is looked for, in order. The website copy comes
    /// first because it is reachable from more networks; the copy in this
    /// package's own repository is the fallback.
    public static let catalogURLs: [URL] = [
        "https://xueshi.dev/more-apps/apps.json",
        "https://raw.githubusercontent.com/XueshiQiao/MoreAppsKit/main/Sources/MoreAppsKit/Resources/apps.json",
    ].compactMap(URL.init(string:))

    /// Linked at the bottom of the page.
    public static let websiteURL = URL(string: "https://xueshi.dev")
}

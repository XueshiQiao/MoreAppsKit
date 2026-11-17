import Foundation

/// The author-specific addresses the package uses unless a host overrides them
/// in `MoreAppsStore.Configuration`.
public enum MoreAppsDefaults {

    /// Where a newer catalog is looked for. Both are the same file, `apps.json`
    /// in the author's apps-list repository, published on GitHub and on Gitee:
    /// neither is reachable from every network. All of them are asked at once
    /// and the answer with the highest revision is used.
    ///
    /// These addresses are compiled into every app that is already installed,
    /// so the repository, its `main` branch and the file must keep their names.
    public static let catalogURLs: [URL] = [
        "https://raw.githubusercontent.com/XueshiQiao/xueshi.dev-apps/main/apps.json",
        "https://gitee.com/qiaoxueshi/xueshi.dev-apps/raw/main/apps.json",
    ].compactMap(URL.init(string:))

    /// Linked at the bottom of the page.
    public static let websiteURL = URL(string: "https://xueshi.dev")
}

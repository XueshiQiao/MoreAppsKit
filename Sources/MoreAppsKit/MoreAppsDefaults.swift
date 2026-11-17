import Foundation

/// The author-specific addresses the package uses unless a host overrides them
/// in `MoreAppsStore.Configuration`.
public enum MoreAppsDefaults {

    /// Where a newer catalog is looked for. All of them serve the same file,
    /// `apps.json` in the author's apps-list repository on GitHub: GitHub's own
    /// raw address, and the jsDelivr network, which mirrors public GitHub
    /// repositories, under three of its host names. No single host is
    /// reachable from every network. All are asked at once and the answer with
    /// the highest revision is used; jsDelivr can lag behind GitHub by up to
    /// 12 hours, which that rule absorbs.
    ///
    /// (Gitee was tried as the second place and ruled out on 2026-11-17: it
    /// treats an app reading a raw file as link abuse and closes the
    /// repository to the public.)
    ///
    /// These addresses are compiled into every app that is already installed,
    /// so the repository, its `main` branch and the file must keep their names.
    public static let catalogURLs: [URL] = [
        "https://raw.githubusercontent.com/XueshiQiao/xueshi.dev-apps/main/apps.json",
        "https://cdn.jsdelivr.net/gh/XueshiQiao/xueshi.dev-apps@main/apps.json",
        "https://fastly.jsdelivr.net/gh/XueshiQiao/xueshi.dev-apps@main/apps.json",
        "https://gcore.jsdelivr.net/gh/XueshiQiao/xueshi.dev-apps@main/apps.json",
    ].compactMap(URL.init(string:))

    /// Linked at the bottom of the page.
    public static let websiteURL = URL(string: "https://xueshi.dev")
}

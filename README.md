# MoreAppsKit

A "More Apps" page for macOS apps by the same author. Each app that embeds it
lists the author's other apps, and the user can get one with a single click:
the package downloads the app, checks its signature, puts it in the
Applications folder and opens it.

It is one Swift package with no dependencies (macOS 13+, SwiftUI + AppKit).
English and Simplified Chinese are built in.

## What the user sees

- A page meant for a settings sidebar: a large card for one recommended app,
  then a "Not Installed" list and an "Installed" list. Each row has the app's
  icon, name, a one-line description and one button.
- The button changes with the app's state:

  ```
  Get  →  progress ring (click to cancel)  →  spinner while installing  →  Open
  ```

  An App Store app shows "App Store" and opens its store page. An app that
  needs a newer macOS shows "Requires macOS 14" and no button.
- The app showing the page is left out of its own list.
- With more than 8 apps the page gets a search field.
- `MoreAppsEntryRow` is a single row (icons, count, chevron) for an About
  screen that leads to the page.

## Adding it to an app

1. Add the package (`project.yml` for XcodeGen):

   ```yaml
   packages:
     MoreAppsKit:
       url: https://github.com/<owner>/MoreAppsKit
       from: "1.0.0"
   targets:
     MyApp:
       dependencies:
         - package: MoreAppsKit
   ```

2. Create one store and keep it for the app's lifetime:

   ```swift
   import MoreAppsKit

   let moreApps = MoreAppsStore(configuration: .init(language: "zh-Hans"))  // nil follows the system
   moreApps.onEvent = { event in
       // Forward to the app's own analytics, behind its own opt-out switch.
       Analytics.track(event.name, event.properties)
   }
   ```

3. Show the page and, optionally, the entry row:

   ```swift
   MoreAppsPage(store: moreApps)
       .navigationTitle("More Apps")

   MoreAppsEntryRow(store: moreApps, title: "More Apps") {
       Image(systemName: "square.grid.2x2.fill")   // the host's own row icon
   } action: {
       moreApps.nextViewSource = "about"            // reported with the page view
       showMoreAppsPage()
   }
   ```

4. At launch, report a referred launch (see Analytics):

   ```swift
   if let source = MoreApps.launchReferrer {
       let event = MoreAppsEvent.referredLaunch(source: source)
       Analytics.track(event.name, event.properties)
   }
   ```

5. When the app's language setting changes, set `moreApps.language`.

Recommended placement, as done in AnyDrag: the page sits at the bottom of the
settings sidebar, in a separate group next to About, with no badge and nothing
that pops up on its own. Cross-promotion stays out of the feature list.

### Requirements on the host app

- **Signed with the author's team.** A download must be signed by the same team
  as the host. An unsigned or ad-hoc signed host cannot install; Get then lets
  the browser download the disk image instead.
- **Not sandboxed.** A sandboxed host (a Mac App Store build) cannot write to
  the Applications folder; it gets the same browser fallback.

## The catalog

`Sources/MoreAppsKit/Resources/apps.json` is the list of apps. The order in the
file is the display priority.

```json
{
  "schema": 1,
  "revision": 1,
  "apps": [
    {
      "id": "qduo",
      "name": "QDuo",
      "bundleId": "com.example.qduo",
      "tagline": { "en": "…", "zh-Hans": "…" },
      "homepage": "https://example.com/qduo/",
      "minOS": "13.0",
      "install": { "kind": "dmg", "url": "https://example.com/QDuo.dmg" }
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `id` | Lowercase letters, digits and `-`. Names the icon file and is the `target` of analytics events. Never change it once published. |
| `bundleId` | Used to tell whether the app is installed, and checked against the app inside the downloaded disk image. |
| `tagline` | One line per language code. Falls back to `en`. |
| `minOS` | Lowest macOS version that runs the app. |
| `icon` | Only for an app whose icon is not bundled: an https URL, or a path relative to the catalog's URL. |
| `install` | `{"kind":"dmg","url":…}` for one universal image, `{"kind":"dmg","urls":{"arm64":…,"x86_64":…}}` for one image per processor, or `{"kind":"appStore","url":…}`. |

Rules the decoder enforces: every link must be `https`; an app that fails to
decode (for example an install kind this version does not know) is skipped and
the rest of the list still loads; a duplicate id is dropped.

### Current list and why

Agreed with the author on 2026-11-17:

1. PastePaw, AnyDrag, QDuo, HyperCapslock, CCSwitcher, Netstat Cat: the apps on
   the author's website, in the website's order.
2. XTools, Attaché, WePaste: included, but placed after the others.
3. Notifier: not listed. Its repository was archived because it is hardly used.

### How a newer catalog reaches users

A copy of `apps.json` is bundled, so the page works offline. When the page is
opened (at most once every 6 hours) the store also fetches the catalog from
`MoreAppsDefaults.catalogURLs`, tried in order: the author's website first,
then the raw file in this repository. Among the bundled, cached and fetched
copies the one with the highest `revision` wins.

So, to add or change an app:

1. Edit `apps.json` and **increase `revision`**.
2. For a new app, add `moreapps-icon-<id>.png` (160 px) to `Resources/`, or set
   `icon` so existing installs can download it.
3. Publish: push this repository and upload the same file to the website.
   Every app in the field picks it up without an update.
4. Run `MOREAPPS_NETWORK_TESTS=all swift test` to prove every download installs.

An incompatible change to the file format must use a new file name, so apps
already in use keep reading `schema` 1.

**Download links must never change.** Every entry uses the form
`…/releases/latest/download/<file>`, which always serves the newest release, so
the catalog does not need editing when an app ships a new version.

- Apps with one universal image publish `<Name>.dmg`.
- The Tauri apps (Netstat Cat, WePaste) build one image per processor, and
  Tauri puts the version in the file name. Their release workflows therefore
  also publish copies under fixed names, `<Name>_macos_aarch64.dmg` and
  `<Name>_macos_x64.dmg`, and fail if a copy is missing. A new app of this kind
  needs the same step in its release workflow.

## What Get does, exactly

```
the user clicks Get on an app
    if it is an App Store app:
        open its page in the App Store
    if this host cannot install (sandboxed, or not signed with a team):
        let the browser download the disk image
    download the disk image into a private temporary folder
    mount it read-only, hidden from Finder
    find the .app whose bundle id is the one the catalog names
        (none: stop, "did not pass the signature check")
    check the app's code signature:
        Developer ID Application certificate, issued by Apple,
        belonging to the same team that signed the host app
        (anything else: delete the download, stop)
    if an app of that name is already in the Applications folder:
        same bundle id: leave it untouched and treat it as installed
        different bundle id: stop, nothing is overwritten
    if the Applications folder is not writable (a non-admin account):
        move the verified disk image to ~/Downloads and open it
    copy the app next to its destination, check the copy's signature again,
    move it into place, unmount, delete the temporary files
    open the app
```

Design points:

- **The signature check is the security boundary.** A file this process
  downloads carries no quarantine flag, so Gatekeeper does not inspect it on
  first launch. Nothing in the catalog can relax the check: the trusted team is
  read from the host app's own signature, not from any file.
- **Installed apps are never overwritten.** Updating an installed app is that
  app's own job (Sparkle).
- **"Installed" means in an Applications folder** (`/Applications` or
  `~/Applications`). Copies elsewhere, such as build products, do not count.
- The check does not require a stapled notarization ticket, because not every
  release has one stapled (CCSwitcher's does not). It also does not do an online
  revocation check, which would fail whenever Apple's servers are unreachable.

## Analytics

The package sends nothing itself. It hands events to `onEvent`; the host
forwards them to its own analytics, honouring its own opt-out. All hosts report
the same names, so the dashboards of different apps are comparable.

| Event | Properties | When |
|---|---|---|
| `more_apps_viewed` | `source` (`sidebar`, `about`, `menu`, `window`), `apps` (count listed) | the page appears. `window` means the settings window was reopened while already on this page; the host has to report that case itself by calling `pageAppeared()`, because SwiftUI does not call `onAppear` again. |
| `more_apps_get_clicked` | `target`, `kind` (`dmg`, `app_store`), `placement` (`featured`, `list`) | Get or App Store clicked |
| `more_apps_install_succeeded` | `target`, `seconds` | installed and opened |
| `more_apps_install_cancelled` | `target` | download cancelled |
| `more_apps_install_failed` | `target`, `stage` (`download`, `mount`, `verify`, `copy`), `reason` | an install stopped |
| `more_apps_manual_fallback` | `target`, `via` (`disk_image`, `browser`) | the user was sent to finish by hand |
| `more_apps_open_clicked` | `target` | Open clicked on an installed app |
| `more_apps_homepage_clicked` | `target` | a row was clicked |
| `more_apps_referred_launch` | `source` | reported by the *installed* app, see below |

`target` is the catalog id of the promoted app (`qduo`). No event describes the
user's other software.

The funnel in the host's dashboard: `viewed` → `get_clicked` →
`install_succeeded`, split by `target`.

**The receiving side.** An app installed from the page is launched with the
environment variable `MOREAPPS_REFERRER` set to the installing app's id.
`MoreApps.launchReferrer` reads it. The installed app reports
`more_apps_referred_launch` with that `source`, so its own dashboard shows
which sibling apps send users. It fires on that first launch only.

## Development

```bash
swift test                               # offline tests
MOREAPPS_NETWORK_TESTS=1 swift test      # + the real installer on one small app
MOREAPPS_NETWORK_TESTS=all swift test    # + every app in the catalog, both processors
```

The network tests install into a temporary folder, never into `/Applications`.
They read the signing team from one of the catalog's apps installed in
`/Applications`, and skip if there is none.

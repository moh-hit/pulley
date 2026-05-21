<p align="center">
  <img src="assets/banner.png" alt="Pulley" width="600">
</p>

<h1 align="center">Pulley</h1>

<p align="center">
  A tiny macOS menu-bar app that keeps your GitHub pull requests one click away —
  and checks each branch out as a git worktree so your main checkout stays clean.
</p>

<p align="center">
  <a href="https://github.com/moh-hit/pulley/releases/latest">
    <img alt="Latest release" src="https://img.shields.io/github/v/release/moh-hit/pulley?style=flat-square">
  </a>
  <a href="https://github.com/moh-hit/pulley/blob/main/LICENSE">
    <img alt="License" src="https://img.shields.io/github/license/moh-hit/pulley?style=flat-square">
  </a>
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square">
  <img alt="Swift" src="https://img.shields.io/badge/swift-5.9-orange?style=flat-square">
</p>

---

## Features

- **Live PR list** across one or many GitHub orgs, filtered by your role
  (authored / involves / review-requested / assigned).
- **Sectioned views.** Group by review status, by repo, or — with multiple
  orgs configured — by org.
- **Open in IDE** with one click. Creates a sibling git worktree at
  `<base>/<repo>--<branch-slug>` so your existing checkout is left alone. If
  the branch is already checked out elsewhere, that worktree is reused.
- **Multi-org** support with per-org coloring and an `org/repo` chip when
  repo names collide.
- **Smart syncing.** Refreshes on demand, on a 30-minute background timer,
  and on popover open if the cache is older than 10 minutes.
- **Token in Keychain**, never on disk.
- **No Dock icon, no main window.** Runs as a proper `LSUIElement` menu-bar
  citizen.

## Install

### Download

Grab the latest `Pulley-<version>.dmg` from the [Releases page][releases],
open it, drag `Pulley.app` to `/Applications`.

The app is signed ad-hoc (no developer certificate). On first launch macOS
will quarantine it; right-click the app → **Open** → **Open** to whitelist.

[releases]: https://github.com/moh-hit/pulley/releases

### Build from source

Requires Xcode 15+ / Swift 5.9, macOS 13+.

```sh
git clone https://github.com/moh-hit/pulley.git
cd pulley
./build.sh
open Pulley.app
```

## Configure

Open the popover from the menu-bar icon → gear → **Settings**.

| Field                 | Notes                                                                                         |
| --------------------- | --------------------------------------------------------------------------------------------- |
| Personal access token | GitHub **classic** PAT with `repo` and `read:org` scopes. Stored in macOS Keychain.           |
| Organizations         | One or more GitHub orgs. Use the **+** button to add another row.                             |
| Default scope         | Which PRs to show — authored by you, involving you, review requested, or assigned.            |
| Preferred IDE         | VS Code, Cursor, or Zed. Tiles show the installed app's icon; uninstalled IDEs render dimmed. |
| Workspace base dir    | Where Pulley looks for clones. Tries `<base>/<repo>` first, then `<base>/<org>/<repo>`.       |
| Launch at login       | Toggled via `SMAppService`.                                                                   |

> Fine-grained tokens won't work — the cross-org PR enumeration relies on the
> classic-token-only `/search/issues` endpoint.

## How "Open in IDE" works

When you click the `</>` icon on a PR row, Pulley:

1. Locates the repo at `<base>/<repo>` or `<base>/<org>/<repo>`.
2. Asks git (`worktree list --porcelain`) whether the branch is already
   checked out anywhere. If yes, that worktree is reused.
3. Otherwise runs `git fetch origin <branch>` and
   `git worktree add <base>/<repo>--<slug> <branch>` as a sibling of the
   repo, with `worktree.guessRemote=true` so a fresh branch tracks
   `origin/<branch>`.
4. Opens the resulting path in your chosen IDE.

The spinner on the row tells you when git is working.

## Releases

Versioning lives in `Info.plist` (`CFBundleShortVersionString`). The release
script stamps it, rebuilds, and produces a compressed DMG with an
`/Applications` shortcut for drag-to-install.

```sh
./release.sh 1.2.0
```

Output:

```
Pulley.app                      ← rebuilt bundle
dist/Pulley-1.2.0.dmg           ← shippable DMG
```

`CFBundleVersion` is set to a `YYYYMMDDHHMM` build number so macOS treats
each release as strictly newer than the last, independent of the marketing
version.

Running `./release.sh` with no arguments reuses the version currently in
`Info.plist` (useful for rebuilding without bumping).

### Automated releases

`.github/workflows/release.yml` runs on every `v*` tag push: it checks out
on a macOS runner, runs `./release.sh <version>` (with the leading `v`
stripped), and uploads the DMG to a GitHub Release with auto-generated
notes.

```sh
git tag v1.2.0
git push origin v1.2.0
```

### Styled installer

If `dmg-bg.webp` (or `dmg-bg.png`) is present in the repo root, the DMG is
decorated with that artwork plus a drag-to-Applications layout — app icon on
the left, `Applications` shortcut on the right. The background is scaled to
`(WIN_W × 2) × (WIN_H × 2)` so it renders crisply on retina displays.

The layout is applied via AppleScript driving Finder, so the first run will
prompt for **System Settings → Privacy & Security → Automation** access
("Terminal wants to control Finder"). Approve it once and subsequent
releases are silent. Without the background image the script falls back to
a plain DMG.

## Project layout

```
Package.swift                  – SwiftPM executable target
Info.plist                     – bundle id app.skyhit.pulley, LSUIElement=true
build.sh                       – swift build → Pulley.app
release.sh                     – ./build.sh + hdiutil → dist/Pulley-<v>.dmg
.github/workflows/release.yml  – tag-push → DMG → GitHub Release
Sources/Pulley/
  App.swift                    – AppDelegate, NSStatusItem, NSPopover plumbing
  ContentView.swift            – popover root, PR sections + rows
  SettingsView.swift           – in-popover settings page (no SwiftUI sheet)
  Store.swift                  – ObservableObject backing the PR list
  GitHubClient.swift           – /search/issues + /repos/.../pulls fan-out
  Models.swift                 – PR / Scope / GroupBy / IDE enums
  Actions.swift                – pasteboard, browser open, worktree+IDE flow
  Config.swift                 – UserDefaults + Keychain + launch-at-login
  Resources/                   – menu-bar PNG + Pulley.icns app icon
```

## Implementation notes

- The popover behaves as `.applicationDefined` (not `.transient`) so opening
  an `NSOpenPanel` from Settings doesn't strand the popover or the settings
  page. Outside-app clicks dismiss it via a global event monitor.
- Settings is rendered in place of the main view inside the popover, not as
  a SwiftUI sheet — sheets inside popovers freeze the responder chain on
  dismissal.
- A previous build wrote the GitHub token under the keychain service
  `com.local.pulley`. The current build reads from that as a fallback and
  migrates it to `app.skyhit.pulley` on first launch.

## Contributing

Issues and pull requests are welcome. For anything non-trivial, open an
issue first so we can agree on direction.

1. Fork and create a feature branch off `main`.
2. `./build.sh` to verify the bundle launches cleanly.
3. Open a PR with a concise summary of the change and the user-visible
   behavior.

## License

[MIT](LICENSE) © Mohit Kumar

# DirBuff

**`/tmp` for your own folders.** A macOS menu-bar app that gives ordinary Finder folders opt-in
capabilities, called buffs. Right-click a folder → **DirBuff: Add Buff › Temporary**, or drag the
buff from DirBuff onto it, and DirBuff clears old files out of it from then on.

Download DirBuff, with automatic updates, from [dirbuff.fsh.ba](https://dirbuff.fsh.ba)
(price and licence there) or from [Releases](https://github.com/fishballapp/dirbuff/releases).
Licensed under [GPL-3.0](LICENSE).

## Temporary

A Temporary folder has one rule. An item is cleared when the rule says so, at the next clean-up:
on the hour, by the clock, and at no other time.

| Rule | Behaviour |
| --- | --- |
| Age | Not added or changed for N days (default 90) |
| Size | Keep the folder under X GB, oldest out first |
| Automatic | Like `/tmp`: keep everything while the disk has room; below 10% free, oldest out until it's back. Always deletes permanently |
| Empty on restart | The first clean-up after a restart clears what was there before it |

- Each top-level item is judged on its own. A subfolder counts as its newest content; a package
  (`.app`, `.photoslibrary`) is one item. Hidden items are left alone.
- Items are moved to the Bin, so you can put them back (Finder's Put Back works too), or deleted
  permanently, per folder.
- Temporary never goes on your home folder, its Library, system folders or the top of a disk:
  clearing them would break the Mac.
- DirBuff lists a folder's items and their dates. It never reads a file's contents.

## Backup

A folder wearing Backup is copied to the user's own Google Drive, with every version kept: the
latest 10, then hourly for 48 hours, daily for 30 days, weekly for 12 weeks, monthly for 24 months
and one a year. Backup asks Google for the `drive.file` scope only, so DirBuff sees just the files it
creates there, and no server of ours receives them. A backup is a [restic](https://restic.net)
repository, so restic alone reads it without DirBuff; the folder in Drive carries a `README.txt` with
the commands, and [dirbuff.fsh.ba/restore](https://dirbuff.fsh.ba/restore) shows them.

- Browse Backup… opens any backup as a folder in Finder's column view: restore an item, or drag it
  out.
- It has no password unless one is set in Settings › Backup, kept in the Keychain.
- It leaves out `~/Library` under the home folder, the Photos library (not backed up yet), what Time
  Machine skips, cache folders, `node_modules`-like folders and files only in iCloud.
- The bundled restic is built from source in the release job; the app's Swift code does the Google
  sign-in and every Drive call, and restic reaches Drive through a local bridge.

## How it is built

Every capability runs the same pipeline: **snapshot** the folder → **plan** what clears → **preview**
→ **apply** → **journal** for undo. Only the engine touches your files.

| Path | What |
| --- | --- |
| `packages/core` | `DirBuffCore`: the rules and the plan. Pure, no file access |
| `packages/kit` | `DirBuffKit`: the inventory, the SQLite store ([GRDB](https://github.com/groue/GRDB.swift)), the engine, licence checks |
| `packages/ui` | `DirBuffUI`: the SwiftUI views and the state they show |
| `apps/mac` | The app, its Finder extension, and the release tooling |

Swift 6, SwiftUI, macOS 14 or later, [Sparkle](https://sparkle-project.org) for updates.

## Building

Needs macOS 14 or later, Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
swift test --package-path packages/core
swift test --package-path packages/kit
swift test --package-path packages/ui

cd apps/mac
xcodegen generate
xcodebuild -project DirBuff.xcodeproj -scheme DirBuff -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

The tests that act on the real Bin and mount disk images run only with `DIRBUFF_SYSTEM_TESTS=1`;
leave that off on a Mac whose Bin you care about.

The app and its Finder extension share an app group, and Finder only loads an extension that is
signed. To run your own build, set your `DEVELOPMENT_TEAM` and signing identity in
`apps/mac/project.yml`, and change the app group `9CWXH66CKT.app.fishball.dirbuff` to one of your
team's in both `.entitlements` files and `apps/mac/Shared/FinderFolders.swift`.

`swift format lint --strict --recursive apps packages` checks the style, configured by
[`.swift-format`](.swift-format).

## Releases

A release is built, signed, notarised and published by [`release.yml`](.github/workflows/release.yml),
run by a version tag (`v<version>`) on a commit of `main`. The DMG is a GitHub release asset; the update feed Sparkle reads is
`dirbuff.fsh.ba/appcast.xml` (copies built before the move ask `dirbuff.fishball.app/appcast.xml`,
which redirects there), and an update installs only if it is signed with the key whose
public half is `SUPublicEDKey` in `apps/mac/DirBuff/Info.plist`.

Every commit to `main` also ships a signed dev build (a prerelease, `v<version>-dev.<n>`), offered
only to copies that switch on **Get dev builds** in Settings. The newest three are kept; some will
be broken.

## Contributing

This repository is an exported copy of a private monorepo, so a pull request merged here would be
lost on the next export. Open an issue and describe the change, with a diff if you have one; it
will be applied at the source and credited.

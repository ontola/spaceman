# SpaceMan

<img src="assets/logo.png" width="128" alt="SpaceMan logo">

Free up disk space, fast. SpaceMan shows where your space goes, suggests what
can safely be removed and lets you mark things as "do not touch".

A Flutter app on top of a Rust core, connected with
[flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/). macOS comes
first; Windows, Linux, iOS and Android share the same code.

<p>
  <img src="docs/screenshots/desktop-treemap.png" width="640" alt="SpaceMan on macOS: treemap of a folder">
  &nbsp;
  <img src="docs/screenshots/mobile-list.png" width="200" alt="SpaceMan in a phone-sized window: folder list">
</p>

## Features

- **Explore**: drill down through folders, largest first, as a list with
  sizes and shares of the parent folder, or as a treemap. Results appear
  while the scan is still running.
- **Clean up**: suggestions for caches, build output (`node_modules`, Rust
  `target`, Flutter `build`, Xcode DerivedData, ...), logs, the Trash, old
  downloads and files of a gigabyte or more, grouped by kind. Nothing is
  ticked for you.
- **Do not touch**: protect any file or folder. Protected items, and
  everything inside them, are never suggested and cannot be removed.
- Removing moves items to the Trash, so it can be undone. Folders that apps
  expect to exist (caches, Downloads) are emptied instead of removed.

## Fast, and cached

- The scanner walks the disk in parallel (rayon work stealing), measures real
  on-disk size (`st_blocks`), never follows symlinks, stays on one filesystem
  and counts hard links once. A warm scan of a 237k file tree takes ~0.2 s,
  about 5x faster than `du`.
- Scan results are cached on disk (bincode + lz4). On startup the last scan is
  shown instantly, then refreshed in the background.
- Rescans reuse the cached listing of every directory whose modification time
  did not change, so only changed folders are read again: ~30 ms for that
  same tree. Use *Full rescan* (right-click the refresh button) to also pick
  up files that changed size in place.
- Files under 1 MB are folded into one "N smaller files" entry per folder, so
  memory stays small even for millions of files. The tree stays in Rust; the
  UI only asks for the rows it shows.

## Layout

```
rust/src/core/      platform-independent core (no Flutter)
  scan.rs           parallel, incremental scanner
  tree.rs           flat arena tree of the scan
  cache.rs          on-disk scan cache
  rules.rs          cleanup suggestions, per platform
  protect.rs        "do not touch" list
rust/src/api/       the API exposed to Dart (flutter_rust_bridge)
lib/                Flutter UI
lib/src/rust/       generated bindings, do not edit
rust_builder/       cargokit glue that builds the Rust crate per platform
```

## Development

Requirements: Flutter (stable), Rust (stable). On macOS also Xcode; on
Windows Visual Studio with the "Desktop development with C++" workload.

```sh
flutter run -d macos           # builds the Rust crate automatically
cd rust && cargo test          # core tests
cargo run --release --example scan -- ~ /tmp/scan.bin   # benchmark
```

After changing anything in `rust/src/api/`, regenerate the bindings:

```sh
cargo install flutter_rust_bridge_codegen cargo-expand
flutter_rust_bridge_codegen generate
```

The logo is drawn in code (`lib/widgets/logo.dart`) from the colours in
`lib/palette.dart`, which the theme and the treemap use too. After changing
either, regenerate the app icons, Android adaptive icon and splash screens for macOS,
iOS, Windows and Android:

```sh
flutter test tool/generate_icons.dart
```

### macOS notes

The app is not sandboxed, because it needs to read the whole disk and use the
Trash. That rules out the Mac App Store; distribute it signed and notarized
instead. To scan protected locations (Mail, Messages, other users' folders),
grant SpaceMan *Full Disk Access* in System Settings > Privacy & Security.

#### Installer

`tool/make_dmg.sh` builds `build/SpaceMan.dmg`: a window with SpaceMan and
the Applications folder to drag it onto. Its background is drawn by
`tool/generate_icons.dart` and the layout lives in `macos/dmg/settings.py`.
Without signing settings the app only has an ad-hoc signature and macOS
blocks the first start (System Settings > Privacy & Security > *Open
Anyway*). To sign and notarize it locally:

```sh
xcrun notarytool store-credentials spaceman   # once: Apple ID, team ID, app-specific password
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=spaceman tool/make_dmg.sh
```

CI does the same when these repository secrets are set (Settings > Secrets
and variables > Actions); without them it still builds an unsigned DMG.

| Secret | What |
| --- | --- |
| `MACOS_CERT_P12` | A *Developer ID Application* certificate with its private key, exported from Keychain Access as .p12 and base64 encoded (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERT_PASSWORD` | The password chosen for that .p12 export |
| `APPLE_ID` | Apple ID email of a member of the developer team |
| `APPLE_TEAM_ID` | The 10-character team ID, shown in brackets in the certificate's name |
| `APPLE_APP_PASSWORD` | An app-specific password for that Apple ID, made at account.apple.com > Sign-In and Security |

A Developer ID certificate can only be created by the team's Account
Holder: in Xcode, Settings > Accounts > Manage Certificates > + >
*Developer ID Application*, or at developer.apple.com > Certificates.

### Windows notes

`flutter run -d windows` or `flutter build windows --release`; the app is
`build\windows\x64\runner\Release\SpaceMan.exe` with the DLLs and `data`
folder next to it. No permissions are needed. Removed items go to the Recycle
Bin. Files in OneDrive that are only in the cloud count as taking no space.

CI publishes the macOS DMG and an unsigned Windows zip as the `dev`
prerelease.

### Android notes

SpaceMan scans shared storage (`/storage/emulated/0`) and needs *All files
access* (`MANAGE_EXTERNAL_STORAGE`) for that; the app asks on first start.
Android has no trash for apps, so removing deletes permanently. Other apps'
private data (`Android/data`) stays out of reach, even with that permission.
Google Play only allows this permission for file managers and the like, so
for now the APK is installed directly.

```sh
flutter run -d <device>                    # needs the Android SDK and NDK
flutter build apk --target-platform android-arm64
```

CI publishes `SpaceMan-Android.apk` with every development build. It is
signed with CI's throwaway debug key, so uninstall the previous build before
installing a new one.

## Ideas

- FSEvents (macOS) / USN journal (Windows) for instant, exact incremental scans
- Duplicate file finder
- Treemap / sunburst view
- Docker, Homebrew and simulator cleanup through their own CLIs

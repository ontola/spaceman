# SpaceMan

Free up disk space, fast. SpaceMan shows where your space goes, suggests what
can safely be removed and lets you mark things as "do not touch".

A Flutter app on top of a Rust core, connected with
[flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/). macOS comes
first; Windows, Linux, iOS and Android share the same code.

## Features

- **Explore**: drill down through folders, largest first, with sizes and
  shares of the parent folder.
- **Clean up**: suggestions for caches, build output (`node_modules`, Rust
  `target`, Flutter `build`, Xcode DerivedData, ...), logs, the Trash, old
  downloads and large files that have not been touched in months. Items that
  are regenerated automatically are preselected; the rest is "worth a look".
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

### macOS notes

The app is not sandboxed, because it needs to read the whole disk and use the
Trash. That rules out the Mac App Store; distribute it signed and notarized
instead. To scan protected locations (Mail, Messages, other users' folders),
grant SpaceMan *Full Disk Access* in System Settings > Privacy & Security.

### Windows notes

`flutter run -d windows` or `flutter build windows --release`; the app is
`build\windows\x64\runner\Release\SpaceMan.exe` with the DLLs and `data`
folder next to it. No permissions are needed. Removed items go to the Recycle
Bin. Files in OneDrive that are only in the cloud count as taking no space.

CI publishes unsigned macOS and Windows zips as the `dev` prerelease.

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

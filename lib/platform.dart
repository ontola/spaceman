import 'dart:io';

/// Name of the system file manager, for menu labels.
String get fileManagerName {
  if (Platform.isMacOS) return 'Finder';
  if (Platform.isWindows) return 'Explorer';
  return 'file manager';
}

bool get canReveal =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Shows [path] in the system file manager, selected where supported.
Future<void> reveal(String path) async {
  if (Platform.isMacOS) {
    await Process.run('open', ['-R', path]);
  } else if (Platform.isWindows) {
    await Process.run('explorer', ['/select,', path]);
  } else if (Platform.isLinux) {
    final target = FileSystemEntity.isDirectorySync(path)
        ? path
        : File(path).parent.path;
    await Process.run('xdg-open', [target]);
  }
}

/// Whether removed items go to a trash the user can restore from.
bool get hasTrash => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Opens the Full Disk Access pane of System Settings (macOS only).
Future<void> openFullDiskAccessSettings() async {
  await Process.run('open', [
    'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles',
  ]);
}

/// Quits and starts the app again, e.g. so macOS applies a new permission.
Future<void> relaunchApp() async {
  if (Platform.isMacOS) {
    // .../SpaceMan.app/Contents/MacOS/SpaceMan -> .../SpaceMan.app
    final bundle = File(Platform.resolvedExecutable).parent.parent.parent.path;
    // Wait for this process to exit before opening the app again,
    // otherwise `open` just focuses the running instance.
    await Process.start('/bin/sh', [
      '-c',
      'while kill -0 $pid 2>/dev/null; do sleep 0.1; done; open "\$0"',
      bundle,
    ], mode: ProcessStartMode.detached);
  } else {
    await Process.start(
      Platform.resolvedExecutable,
      [],
      mode: ProcessStartMode.detached,
    );
  }
  exit(0);
}

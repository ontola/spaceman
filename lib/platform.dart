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

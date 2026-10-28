/// Small helpers for the paths the core hands out, which use `/` on macOS,
/// Linux and Android and `\` on Windows.
library;

bool _isSeparator(String c) => c == '/' || c == r'\';

/// Whether [path] lies inside [folder] (and is not [folder] itself).
bool isInside(String path, String folder) =>
    path.length > folder.length &&
    path.startsWith(folder) &&
    _isSeparator(path[folder.length]);

/// [path] relative to the home folder, as `~/...` (or `~\...`).
String homeRelative(String path, String? home) =>
    home != null && isInside(path, home)
    ? '~${path.substring(home.length)}'
    : path;

/// [path] shortened in the middle to about [max] characters, keeping the
/// start and the more telling end.
String middleEllipsis(String path, [int max = 72]) {
  if (path.length <= max) return path;
  final head = (max * 0.4).round();
  return '${path.substring(0, head)}…${path.substring(path.length - (max - head - 1))}';
}

/// The last component of [path], or [path] itself when it has none (`/`).
String lastComponent(String path) {
  final parts = path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

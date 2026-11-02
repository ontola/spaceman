/// Human-readable byte sizes, using decimal units like Finder does.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// [formatBytes] for an item still being scanned, whose size can only
/// grow: shown as a lower bound.
String formatSize(int bytes, {bool growing = false}) =>
    growing ? '≥ ${formatBytes(bytes)}' : formatBytes(bytes);

String formatCount(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

/// Short counts for tight spaces: 950, 12K, 8.3M.
String formatCompact(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}K';
  }
  return '${(n / 1000000).toStringAsFixed(n < 10000000 ? 1 : 0)}M';
}

/// "3 minutes ago" style description of a Unix timestamp in seconds.
String formatAgo(int unixSeconds, {DateTime? now}) {
  final then = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  final diff = (now ?? DateTime.now()).difference(then);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes} min ago';
  if (diff.inDays < 1) return '${diff.inHours} h ago';
  return '${diff.inDays} days ago';
}

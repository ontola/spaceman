import 'package:flutter_test/flutter_test.dart';
import 'package:spaceman/format.dart';

void main() {
  test('formatBytes uses decimal units', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(999), '999 B');
    expect(formatBytes(1500), '1.5 KB');
    expect(formatBytes(250 * 1000 * 1000), '250 MB');
    expect(formatBytes(12345678901), '12.3 GB');
  });

  test('formatSize marks growing sizes as a lower bound', () {
    expect(formatSize(1500), '1.5 KB');
    expect(formatSize(1500, growing: true), '≥ 1.5 KB');
  });

  test('formatCount groups thousands', () {
    expect(formatCount(7), '7');
    expect(formatCount(1234567), '1,234,567');
  });

  test('formatAgo', () {
    final now = DateTime(2026, 1, 2, 12);
    int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch ~/ 1000;
    expect(formatAgo(ago(const Duration(seconds: 5)), now: now), 'just now');
    expect(formatAgo(ago(const Duration(minutes: 5)), now: now), '5 min ago');
    expect(formatAgo(ago(const Duration(days: 3)), now: now), '3 days ago');
  });
}

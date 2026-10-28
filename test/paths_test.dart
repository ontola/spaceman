import 'package:flutter_test/flutter_test.dart';
import 'package:spaceman/paths.dart';

void main() {
  test('isInside needs a separator after the folder', () {
    expect(isInside('/a/b', '/a'), isTrue);
    expect(isInside(r'C:\Users\u\x', r'C:\Users\u'), isTrue);
    expect(isInside('/a', '/a'), isFalse);
    expect(isInside('/ab', '/a'), isFalse);
    expect(isInside('/a', '/a/b'), isFalse);
  });

  test('homeRelative shortens paths in the home folder', () {
    expect(
      homeRelative('/Users/u/Library/Caches', '/Users/u'),
      '~/Library/Caches',
    );
    expect(homeRelative(r'C:\Users\u\AppData', r'C:\Users\u'), r'~\AppData');
    expect(homeRelative('/Users/u', '/Users/u'), '/Users/u');
    expect(homeRelative('/Users/uu/x', '/Users/u'), '/Users/uu/x');
    expect(homeRelative('/x', null), '/x');
  });

  test('middleEllipsis keeps both ends', () {
    expect(middleEllipsis('/short'), '/short');
    final long = '/${'a' * 50}/${'b' * 50}/end.txt';
    final short = middleEllipsis(long, 20);
    expect(short.length, 20);
    expect(short, startsWith('/aaaaaa'));
    expect(short, endsWith('b/end.txt'));
    expect(short, contains('…'));
  });

  test('lastComponent', () {
    expect(lastComponent('/Users/u'), 'u');
    expect(lastComponent('/Users/u/'), 'u');
    expect(lastComponent(r'C:\Users\u'), 'u');
    expect(lastComponent('/'), '/');
  });
}

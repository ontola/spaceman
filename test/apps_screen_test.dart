import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spaceman/app_model.dart';
import 'package:spaceman/screens/apps.dart';

import 'support/fake_core.dart';

void main() {
  setUpFakes();
  const channel = MethodChannel('spaceman/storage');
  late bool usageAccess;
  late List<MethodCall> calls;

  setUp(() {
    usageAccess = true;
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'hasUsageAccess' => usageAccess,
            'appSizes' => {
              'total': 64000000000,
              'free': 20000000000,
              'apps': [
                {
                  'package': 'com.big',
                  'label': 'Big app',
                  'app': 2000000000,
                  'data': 6000000000,
                  'cache': 1000000000,
                  'system': false,
                },
                {
                  'package': 'com.small',
                  'label': 'Small app',
                  'app': 100000000,
                  'data': 50000000,
                  'cache': 0,
                  'system': false,
                },
                {
                  'package': 'com.android.system',
                  'label': 'Built in',
                  'app': 300000000,
                  'data': 0,
                  'cache': 0,
                  'system': true,
                },
              ],
            },
            _ => null,
          };
        });
  });

  /// The model loads app sizes itself on Android; [AppModel.init] does
  /// that at start and on resume, here the test calls it.
  Future<AppModel> pump(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final model = AppModel();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AppsScreen(model: model)),
      ),
    );
    await tester.runAsync(model.loadApps);
    await tester.pumpAndSettle();
    return model;
  }

  testWidgets('explains usage access until it is granted', (tester) async {
    usageAccess = false;
    final model = await pump(tester);
    expect(find.text('Most of your space is in apps'), findsOneWidget);
    await tester.tap(find.text('Allow usage access'));
    expect(calls.last.method, 'requestUsageAccess');

    // Back from Settings with access granted.
    usageAccess = true;
    await tester.runAsync(model.loadApps);
    await tester.pumpAndSettle();
    expect(find.text('Big app'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('lists apps by size, built-in ones on request', (tester) async {
    await pump(tester);
    expect(find.text('Apps and their data'), findsOneWidget);
    expect(find.text('8.4 GB'), findsWidgets);
    expect(
      find.text('App 2.0 GB · Data 5.0 GB · Cache 1.0 GB'),
      findsOneWidget,
    );
    final big = tester.getTopLeft(find.text('Big app'));
    final small = tester.getTopLeft(find.text('Small app'));
    expect(big.dy, lessThan(small.dy));
    expect(find.text('Built in'), findsNothing);

    await tester.tap(find.text('Built-in apps'));
    await tester.pumpAndSettle();
    expect(find.text('Built in'), findsOneWidget);

    await tester.tap(find.text('Small app'));
    expect(calls.last.method, 'openAppInfo');
    expect(calls.last.arguments, {'package': 'com.small'});
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('shows errors from Android', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'hasUsageAccess') return true;
          throw PlatformException(code: 'denied', message: 'no');
        });
    await pump(tester);
    expect(find.textContaining('denied'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}

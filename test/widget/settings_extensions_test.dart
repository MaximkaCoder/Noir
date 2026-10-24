import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/router.dart';
import 'package:noir/features/settings/presentation/settings_screen.dart';

import '../helpers/pump_app.dart';

void main() {
  Future<TestApp> openSettings(
    WidgetTester tester, {
    List<WidgetBuilder> extensions = const [],
  }) async {
    final app = await TestApp.pump(
      tester,
      withMusic: false,
      overrides: [
        if (extensions.isNotEmpty)
          settingsExtensionsProvider.overrideWithValue(extensions),
      ],
    );
    app.container.read(routerProvider).go('/settings');
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('shows no extra section by default', (tester) async {
    await openSettings(tester);
    expect(find.text('Resume previous session'), findsOneWidget);
    expect(find.byKey(const ValueKey('extension')), findsNothing);
  });

  testWidgets('shows a registered section after Playback', (tester) async {
    await openSettings(
      tester,
      extensions: [
        (_) => const Text('Extra section', key: ValueKey('extension')),
      ],
    );
    final extra = find.byKey(const ValueKey('extension'));
    expect(extra, findsOneWidget);
    expect(
      tester.getTopLeft(extra).dy,
      greaterThan(tester.getTopLeft(find.text('Resume previous session')).dy),
    );
  });
}

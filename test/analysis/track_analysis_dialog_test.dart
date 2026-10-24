import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/router.dart';
import 'package:noir/features/analysis/application/analysis_providers.dart';
import 'package:noir/features/library/data/library_repository.dart';

import '../helpers/pump_app.dart';
import 'analysis_queue_test.dart' show fakeAnalysis;

void main() {
  testWidgets('a track menu shows its stored analysis', (tester) async {
    final app = await TestApp.pump(tester);
    await tester.runAsync(() async {
      final store = app.container.read(analysisStoreProvider);
      final tracks = await LibraryRepository(app.db).watchTracks().first;
      for (final t in tracks) {
        await store.write(t.id, fakeAnalysis(bpm: 124));
      }
    });
    app.container.read(routerProvider).go('/library?tab=tracks');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('More').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show analysis'));
    await tester.pump();
    // The store reads from disk.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Track analysis'), findsOneWidget);
    expect(find.textContaining('124.0 BPM'), findsOneWidget);
    expect(find.textContaining('A minor (8A)'), findsOneWidget);
    expect(find.text('Analyse again'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Track analysis'), findsNothing);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/theme/app_theme.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/features/youtube/application/youtube_save.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/features/youtube/presentation/save_button.dart';
import 'package:noir/integrations/youtube_data/youtube_api.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/widgets/track_row.dart';

import '../helpers/fake_engine.dart';
import '../helpers/fake_http.dart';
import '../helpers/test_database.dart';
import '../youtube/youtube_fakes.dart';

const _local = Track(
  id: 'local:1',
  source: MediaSource.local,
  title: 'Ash & Ember',
  uri: r'C:\Music\a.mp3',
  isFavorite: true,
);

const _youtube = Track(
  id: 'yt:v2',
  source: MediaSource.youtube,
  title: 'Night Song',
  uri: 'v2',
  artist: 'Mara Vale',
);

class _Harness {
  _Harness(this.container, this.account, this.http);

  final ProviderContainer container;
  final FakeAccount account;
  final FakeHttp http;

  static Future<_Harness> pump(
    WidgetTester tester, {
    bool canWrite = true,
    bool withTarget = true,
  }) async {
    final db = inMemoryDatabase();
    final http = FakeHttp((_) => error(404, {}));
    final account = FakeAccount()
      ..set(AccountStatus.connected, canWrite: canWrite);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        playbackEngineProvider.overrideWithValue(FakeEngine()),
        initialSettingsProvider.overrideWithValue(const AppSettings()),
        httpClientProvider.overrideWithValue(http.dio()),
        accountServiceProvider.overrideWithValue(account),
      ],
    );
    await tester.runAsync(() async {
      final repo = container.read(youTubeRepositoryProvider);
      await repo.savePlaylists(const [
        YtPlaylist(id: 'PLt', title: 'NOIR Likes', itemCount: 0, etag: 'e'),
      ]);
    });
    if (withTarget) {
      container
          .read(saveTargetProvider.notifier)
          .set(const SaveTarget('PLt', 'NOIR Likes'));
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildNoirTheme(Brightness.dark, Density.comfortable),
          home: const Scaffold(
            body: Column(
              children: [
                TrackRow(track: _local, onPlay: _noop),
                TrackRow(track: _youtube, onPlay: _noop),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await db.close();
    });
    return _Harness(container, account, http);
  }
}

void _noop() {}

Finder _rowOf(Track t) =>
    find.ancestor(of: find.text(t.title), matching: find.byType(TrackRow));

void main() {
  testWidgets('local rows keep the local favorite and get no YouTube heart', (
    tester,
  ) async {
    await _Harness.pump(tester);
    expect(
      find.descendant(
        of: _rowOf(_local),
        matching: find.byType(YouTubeSaveButton),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: _rowOf(_local),
        matching: find.byIcon(Icons.favorite_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _rowOf(_youtube),
        matching: find.byType(YouTubeSaveButton),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the heart is hidden while no account is connected', (
    tester,
  ) async {
    final h = await _Harness.pump(tester);
    h.account.set(AccountStatus.disconnected);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Save to NOIR Likes'), findsNothing);
  });

  testWidgets('without a target the heart opens the playlist picker', (
    tester,
  ) async {
    await _Harness.pump(tester, withTarget: false);
    await tester.tap(find.byTooltip('Save to a YouTube playlist'));
    await tester.pumpAndSettle();
    expect(find.text('Save hearted songs to'), findsOneWidget);
    expect(find.text('Create new playlist…'), findsOneWidget);
    expect(find.text('NOIR Likes'), findsOneWidget);
  });

  testWidgets('403 insufficientPermissions leads to the permission prompt, '
      'then the save is retried', (tester) async {
    final h = await _Harness.pump(tester);
    var denied = true;
    h.http.handler = (_) {
      if (denied) {
        return error(403, {
          'error': {
            'errors': [
              {'reason': 'insufficientPermissions'},
            ],
          },
        });
      }
      return ok({'id': 'item-v2'});
    };

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Save to NOIR Likes'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('Allow NOIR to edit your playlists?'), findsOneWidget);

    denied = false;
    await tester.tap(find.text('Continue'));
    final saved = find.text('Saved to NOIR Likes');
    for (var i = 0; i < 40 && saved.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(h.account.upgrades, 1);
    expect(h.http.requests.where((r) => r.method == 'POST'), hasLength(2));
    expect(saved, findsOneWidget);
    expect(find.byTooltip('Remove from NOIR Likes'), findsOneWidget);
    // Let the toast finish.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}

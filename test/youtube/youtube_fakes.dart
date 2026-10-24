import 'dart:async';

import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/integrations/google_auth/desktop_oauth_flow.dart';
import 'package:noir/integrations/google_auth/google_oauth_config.dart';

import '../helpers/fake_http.dart';

/// Account that is either connected or not, with a fixed token.
class FakeAccount implements AccountConnectionService {
  final _changes = StreamController<AccountConnection>.broadcast();
  AccountConnection _state = const AccountConnection(
    status: AccountStatus.connected,
  );
  int refreshes = 0;

  /// How [requestWriteAccess] ends: null grants the write scope.
  OAuthException? upgradeError;
  int upgrades = 0;

  void set(AccountStatus status, {bool canWrite = false}) {
    _state = AccountConnection(
      status: status,
      grantedScopes: [
        GoogleOAuthConfig.youtubeReadOnlyScope,
        if (canWrite) GoogleOAuthConfig.playlistWriteScope,
      ],
    );
    _changes.add(_state);
  }

  @override
  AccountConnection get current => _state;
  @override
  Stream<AccountConnection> watch() async* {
    yield _state;
    yield* _changes.stream;
  }

  @override
  Future<String> accessToken({bool forceRefresh = false}) async {
    if (forceRefresh) refreshes++;
    return 'token-$refreshes';
  }

  @override
  Future<void> connect() async {}
  @override
  void cancelConnect() {}
  @override
  Future<void> disconnect() async => set(AccountStatus.disconnected);

  @override
  Future<void> requestWriteAccess() async {
    upgrades++;
    if (upgradeError case final e?) throw e;
    set(AccountStatus.connected, canWrite: true);
  }
}

Map<String, Object?> video(
  String id, {
  String duration = 'PT3M21S',
  String channel = 'Mara Vale - Topic',
  String? category,
}) => {
  'id': id,
  'snippet': {
    'title': 'Song $id',
    'channelTitle': channel,
    'categoryId': ?category,
    'thumbnails': {
      'high': {'url': 'https://i.ytimg.com/$id.jpg'},
    },
  },
  'contentDetails': {'duration': duration},
  'status': {'embeddable': true},
};

Map<String, Object?> item(String videoId, {String privacy = 'public'}) => {
  'id': 'item-$videoId',
  'snippet': {
    'resourceId': {'videoId': videoId},
  },
  'status': {'privacyStatus': privacy},
};

/// A small fake YouTube: two playlists, one paginated, plus likes.
FakeReply youtube(FakeRequest r, {String etagA = 'eA1'}) {
  final q = r.uri.queryParameters;
  switch (r.uri.pathSegments.last) {
    case 'playlists':
      return ok({
        'items': [
          {
            'id': 'PLa',
            'etag': etagA,
            'snippet': {'title': 'Night drive'},
            'contentDetails': {'itemCount': 3},
            'status': {'privacyStatus': 'private'},
          },
          {
            'id': 'PLb',
            'etag': 'eB1',
            'snippet': {'title': 'Focus'},
            'contentDetails': {'itemCount': 1},
          },
        ],
      });
    case 'playlistItems':
      if (q['playlistId'] == 'PLb') {
        return ok({
          'items': [item('v4')],
        });
      }
      return q['pageToken'] == null
          ? ok({
              'items': [item('v1'), item('gone', privacy: 'private')],
              'nextPageToken': 'p2',
            })
          : ok({
              'items': [item('v2')],
            });
    case 'videos':
      if (q['myRating'] == 'like') {
        return ok({
          'items': [video('v9', duration: 'PT1H2M3S', category: '22')],
        });
      }
      return ok({
        'items': [
          for (final id in q['id']!.split(',')) video(id, category: '10'),
        ],
      });
  }
  return error(404, {});
}

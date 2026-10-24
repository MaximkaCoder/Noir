import 'package:drift/drift.dart';

/// Local audio files the user imported or that live in a library folder.
@DataClassName('TrackRecord')
class Tracks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get path => text().unique()();
  TextColumn get title => text()();
  TextColumn get artist => text().nullable()();
  TextColumn get album => text().nullable()();
  TextColumn get albumArtist => text().nullable()();
  IntColumn get trackNumber => integer().nullable()();
  IntColumn get discNumber => integer().nullable()();
  IntColumn get year => integer().nullable()();
  IntColumn get durationMs => integer().nullable()();
  TextColumn get artworkPath => text().nullable()();
  IntColumn get fileSize => integer()();
  DateTimeColumn get modifiedAt => dateTime()();
  DateTimeColumn get addedAt => dateTime()();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
}

/// Folders the user granted NOIR access to; rescanned on demand.
class LibraryFolders extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get path => text().unique()();
  DateTimeColumn get addedAt => dateTime()();
  DateTimeColumn get lastScannedAt => dateTime().nullable()();
}

/// Locally maintained playlists. Never synchronized to any provider.
@DataClassName('PlaylistRow')
class Playlists extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 120)();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get lastOpenedAt => dateTime().nullable()();
}

class PlaylistEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get playlistId =>
      integer().references(Playlists, #id, onDelete: KeyAction.cascade)();
  IntColumn get trackId =>
      integer().references(Tracks, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();
}

/// Plays started inside NOIR. Stays on this device.
class PlayHistory extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get trackId =>
      integer().references(Tracks, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get playedAt => dateTime()();
}

class SearchHistory extends Table {
  TextColumn get query => text()();
  DateTimeColumn get searchedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {query};
}

/// Small JSON documents: app settings and the last playback session.
class KeyValues extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

// ---------------------------------------------------------------- YouTube --
// Cache of data from the YouTube Data API for the connected account. Rows are
// refreshed or deleted within 30 days (YouTube API Services policy III.E.4)
// and all of them are deleted when the account is disconnected.

@DataClassName('YtPlaylistRow')
class YtPlaylists extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  IntColumn get itemCount => integer()();
  TextColumn get etag => text()();
  TextColumn get thumbnailUrl => text().nullable()();
  TextColumn get privacy => text().nullable()();

  /// Order as returned by YouTube.
  IntColumn get position => integer()();
  DateTimeColumn get syncedAt => dateTime()();

  /// Set once the playlist's items have been downloaded for this etag.
  TextColumn get itemsEtag => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('YtVideoRow')
class YtVideos extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get channelTitle => text()();
  IntColumn get durationMs => integer().nullable()();
  TextColumn get thumbnailUrl => text().nullable()();
  BoolColumn get embeddable => boolean().withDefault(const Constant(true))();
  DateTimeColumn get syncedAt => dateTime()();

  /// `snippet.categoryId` ("10" is Music); empty when YouTube sent none.
  /// Null for rows cached before schema v3 — the next sync backfills them.
  TextColumn get categoryId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class YtPlaylistItems extends Table {
  TextColumn get playlistId =>
      text().references(YtPlaylists, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();
  TextColumn get videoId => text()();

  /// `playlistItems` resource id, needed to remove the entry on YouTube.
  /// Null for rows cached before schema v4 until the playlist changes and
  /// is downloaded again (NOIR then looks the id up when removing).
  TextColumn get itemId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {playlistId, position};
}

class YtLikes extends Table {
  TextColumn get videoId => text()();
  IntColumn get position => integer()();

  @override
  Set<Column<Object>> get primaryKey => {videoId};
}

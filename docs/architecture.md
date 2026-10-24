# Architecture

Feature-first, layered. Business logic lives in repositories and controllers,
never in widgets.

```
lib/
  app/            bootstrap, app root, router, shell, theme (tokens, glass)
  core/           database, platform (window chrome), widgets, formatters
  features/
    home | search | library | playlists | playback | queue | settings | accounts
      data/          repositories (Drift), indexer
      domain/        models and interfaces (PlaybackEngine, AccountConnection…)
      application/   Riverpod controllers / providers
      presentation/  screens and widgets
  integrations/
    local_audio/     LocalAudioEngine (just_audio + media_kit on Windows)
    google_auth/     OAuth configuration (Phase 5)
  shared/          models (Track, Album, Playlist, PlaybackState…), widgets
```

## State and dependency injection

Riverpod 3 (`Notifier` / `StreamProvider`, no code generation). Everything
that touches I/O is a provider, so tests override it:

| Provider | Real | Tests |
|---|---|---|
| `databaseProvider` | `AppDatabase.open()` (app support dir) | `NativeDatabase.memory()` |
| `playbackEngineProvider` | `LocalAudioEngine` | `FakeEngine` |
| `initialSettingsProvider` | loaded before `runApp` | literal |
| `appDirectoriesProvider` | path_provider | temp dirs |

## Persistence (Drift / SQLite, schema v1)

`tracks`, `library_folders`, `playlists`, `playlist_entries`, `play_history`,
`search_history`, `key_values` (JSON documents: settings, playback session).
The schema snapshot lives in `drift_schemas/`; `test/data/migration_test.dart`
fails if the schema changes without a new snapshot and migration.

## Playback

```
UI ──commands──▶ PlaybackController (single source of truth, owns the queue)
                     │  load / play / pause / seek / crossfadeTo
                     ▼
               PlaybackEngine  ◀── LocalAudioEngine (two just_audio players)
                     │  events: status, completed, failed; throttled position
                     ▼
   PlaybackState (Riverpod) ──▶ mini players, Now Playing, queue, media session
```

- `PlaybackCapabilities` come from the engine. The UI hides any control whose
  flag is false; a future `YouTubeEmbedEngine` will report no background
  playback, no crossfade and `requiresVisiblePlayer`.
- Position is a separate throttled stream (200–500 ms) so only progress
  widgets rebuild; there are no UI timers.
- Crossfade: the controller starts `crossfadeTo` inside the fade window; the
  engine ramps two players and swaps which one is "active".
- The session (queue ids, index, position, repeat) is saved on track change,
  pause and every 10 s, and restored paused at startup.
- On Android/iOS/macOS, `audio_service` mirrors state to the OS media session
  and forwards its commands to the same controller.

## Library indexing

`LibraryIndexer` walks a user-chosen folder and parses tags
(`audio_metadata_reader`) on a background isolate (`Isolate.run`). Artwork is
written once per album (FNV-1a file names) and decoded at display size
(`cacheWidth`). Unchanged files (same mtime) are skipped; vanished files are
removed. Damaged files are kept with a filename title and fail with a clear
message only if played.

## Design system

`NoirPalette` (ThemeExtension, dark + light), spacing/radius/blur/motion
tokens and breakpoints in `app/theme/design_tokens.dart`. `GlassSurface` is
the only place that applies backdrop blur; `EffectsConfig` combines user
settings with the system reduced-motion flag:

| Setting | Effect |
|---|---|
| Liquid Glass off | opaque surfaces, zero `BackdropFilter`s, same layout |
| Performance mode | blur σ 10 instead of 28, no highlights, no ambient artwork |
| Animations off / system reduced motion | non-essential transitions become instant |

Shell breakpoints: `< 640` bottom navigation, `640–1080` icon rail + bottom
player bar, `≥ 1080` full sidebar with docked player and an optional queue
panel.

## Windows specifics

Frameless window via `window_manager` (`TitleBarStyle.hidden`) with
reference-style window dots (close / minimize / maximize) and a drag layer
*behind* the top bars, so controls receive taps without double-tap delay.
Minimum size 720×520. Media playback through media_kit (libmpv).

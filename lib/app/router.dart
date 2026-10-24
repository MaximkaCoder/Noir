import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/shell/adaptive_shell.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/noir_backdrop.dart';
import 'package:noir/features/home/presentation/home_screen.dart';
import 'package:noir/features/library/presentation/collection_screens.dart';
import 'package:noir/features/library/presentation/library_screen.dart';
import 'package:noir/features/playback/presentation/now_playing_screen.dart';
import 'package:noir/features/playlists/presentation/playlist_screen.dart';
import 'package:noir/features/queue/presentation/queue_panel.dart';
import 'package:noir/features/search/presentation/search_screen.dart';
import 'package:noir/features/settings/presentation/settings_screen.dart';
import 'package:noir/shared/models/media.dart';

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');

final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AdaptiveShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: '/', builder: (_, _) => const HomeScreen())],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/search', builder: (_, _) => const SearchScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/library',
                builder: (_, state) => LibraryScreen(
                  initialTab: LibraryTab.values
                      .where((t) => t.name == state.uri.queryParameters['tab'])
                      .firstOrNull,
                ),
                routes: [
                  GoRoute(
                    path: 'playlist/:id',
                    builder: (_, state) {
                      final id = int.tryParse(state.pathParameters['id'] ?? '');
                      return id == null
                          ? const LibraryScreen()
                          : PlaylistScreen(key: ValueKey(id), id: id);
                    },
                  ),
                  GoRoute(
                    path: 'album',
                    // Deep links without an album fall back to the library.
                    redirect: (_, state) =>
                        state.extra is Album ? null : '/library?tab=albums',
                    builder: (_, state) =>
                        AlbumScreen(album: state.extra! as Album),
                  ),
                  GoRoute(
                    path: 'artist',
                    redirect: (_, state) =>
                        state.extra is String ? null : '/library?tab=artists',
                    builder: (_, state) =>
                        ArtistScreen(artist: state.extra! as String),
                  ),
                  GoRoute(
                    path: 'favorites',
                    builder: (_, _) => const FavoritesScreen(),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (_, _) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/now-playing',
        parentNavigatorKey: _rootKey,
        pageBuilder: (context, state) => CustomTransitionPage(
          key: state.pageKey,
          opaque: false,
          transitionDuration: NoirEffects.of(context).motion(NoirMotion.slow),
          reverseTransitionDuration: NoirEffects.of(context)
              .motion(NoirMotion.medium),
          child: const NowPlayingScreen(),
          transitionsBuilder: (context, animation, _, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: NoirMotion.emphasized,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, 0.06),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            );
          },
        ),
      ),
      GoRoute(
        path: '/queue',
        parentNavigatorKey: _rootKey,
        builder: (_, _) => const Stack(
          fit: StackFit.expand,
          children: [NoirBackdrop(), QueueScreen()],
        ),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

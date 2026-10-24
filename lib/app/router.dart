import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/shell/adaptive_shell.dart';
import 'package:noir/app/shell/navigation.dart';
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
import 'package:noir/features/youtube/presentation/youtube_playlist_screen.dart';
import 'package:noir/shared/models/media.dart';

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');

final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/',
    routes: [
      StatefulShellRoute(
        builder: (context, state, shell) => AdaptiveShell(shell: shell),
        navigatorContainerBuilder: (context, shell, children) =>
            BranchSwitcher(index: shell.currentIndex, children: children),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/',
                pageBuilder: (context, state) =>
                    _page(context, state, const HomeScreen()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/search',
                pageBuilder: (context, state) =>
                    _page(context, state, const SearchScreen()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/library',
                pageBuilder: (context, state) => _page(
                  context,
                  state,
                  LibraryScreen(
                    initialTab: LibraryTab.values
                        .where(
                          (t) => t.name == state.uri.queryParameters['tab'],
                        )
                        .firstOrNull,
                  ),
                ),
                routes: [
                  GoRoute(
                    path: 'playlist/:id',
                    pageBuilder: (context, state) {
                      final id = int.tryParse(state.pathParameters['id'] ?? '');
                      return _page(
                        context,
                        state,
                        id == null
                            ? const LibraryScreen()
                            : PlaylistScreen(key: ValueKey(id), id: id),
                      );
                    },
                  ),
                  GoRoute(
                    path: 'album',
                    // Deep links without an album fall back to the library.
                    redirect: (_, state) =>
                        state.extra is Album ? null : '/library?tab=albums',
                    pageBuilder: (context, state) => _page(
                      context,
                      state,
                      AlbumScreen(album: state.extra! as Album),
                    ),
                  ),
                  GoRoute(
                    path: 'artist',
                    redirect: (_, state) =>
                        state.extra is String ? null : '/library?tab=artists',
                    pageBuilder: (context, state) => _page(
                      context,
                      state,
                      ArtistScreen(artist: state.extra! as String),
                    ),
                  ),
                  GoRoute(
                    path: 'favorites',
                    pageBuilder: (context, state) =>
                        _page(context, state, const FavoritesScreen()),
                  ),
                  GoRoute(
                    path: 'youtube/liked',
                    pageBuilder: (context, state) =>
                        _page(context, state, const YouTubeLikesScreen()),
                  ),
                  GoRoute(
                    path: 'youtube/:id',
                    pageBuilder: (context, state) => _page(
                      context,
                      state,
                      YouTubePlaylistScreen(
                        key: ValueKey(state.pathParameters['id']),
                        id: state.pathParameters['id']!,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                pageBuilder: (context, state) =>
                    _page(context, state, const SettingsScreen()),
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

/// Pages inside the shell branches: the same fade-through as branch
/// switches, instead of the platform default slide.
Page<void> _page(BuildContext context, GoRouterState state, Widget child) {
  final fx = NoirEffects.of(context);
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: fx.motion(NoirMotion.layout),
    reverseTransitionDuration: fx.motion(NoirMotion.layout),
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        AnimatedBuilder(
          animation: Listenable.merge([animation, secondaryAnimation]),
          child: child,
          builder: (context, child) {
            // Covered by a newer page: fade out. Otherwise fade in / rise.
            final out = fadeThrough(secondaryAnimation.value, incoming: false);
            final into = fadeThrough(animation.value, incoming: true);
            return Opacity(
              opacity: out.opacity * into.opacity,
              child: Transform.translate(
                offset: Offset(0, into.dy),
                child: child,
              ),
            );
          },
        ),
  );
}

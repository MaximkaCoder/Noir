import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/router.dart';
import 'package:noir/app/theme/app_theme.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/features/playback/presentation/youtube_video_layer.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';

class NoirApp extends ConsumerWidget {
  const NoirApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp.router(
      title: 'NOIR',
      debugShowCheckedModeBanner: false,
      themeMode: settings.themeMode,
      theme: buildNoirTheme(Brightness.light, settings.density),
      darkTheme: buildNoirTheme(Brightness.dark, settings.density),
      routerConfig: ref.watch(routerProvider),
      // Effects depend on both the user's settings and the system
      // reduced-motion flag, so they are resolved below MediaQuery.
      builder: (context, child) => NoirEffects(
        config: EffectsConfig.resolve(
          settings,
          systemReducedMotion: MediaQuery.disableAnimationsOf(context),
        ),
        // The YouTube video sits above every route so it can move between
        // Now Playing and its floating mini position without reloading.
        child: Stack(
          fit: StackFit.expand,
          children: [
            child!,
            Overlay(
              initialEntries: [
                OverlayEntry(
                  builder: (_) => const Material(
                    type: MaterialType.transparency,
                    child: YouTubeVideoLayer(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

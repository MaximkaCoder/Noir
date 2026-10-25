import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/theme/app_theme.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/noir_backdrop.dart';
import 'package:noir/features/settings/domain/app_settings.dart';

void main() {
  testWidgets('the ambient artwork covers the whole backdrop', (tester) async {
    tester.view
      ..physicalSize = const Size(800, 600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('noir_backdrop_');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNoirTheme(Brightness.dark, Density.comfortable),
        home: NoirEffects(
          config: const EffectsConfig(
            glass: true,
            blurSigma: 10,
            highlights: true,
            ambient: true,
            animations: true,
          ),
          child: NoirBackdrop(artworkPath: '${dir.path}/cover.jpg'),
        ),
      ),
    );
    expect(tester.getSize(find.byType(Image)), const Size(800, 600));
  });
}

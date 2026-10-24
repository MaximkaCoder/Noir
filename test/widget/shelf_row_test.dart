import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/theme/app_theme.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/shelf_row.dart';
import 'package:noir/features/settings/domain/app_settings.dart';

const _effects = EffectsConfig(
  glass: false,
  blurSigma: 0,
  highlights: false,
  ambient: false,
  animations: true,
);

/// 20 items of 100 px with 16 px gaps (116 px per item) in an 800 px wide
/// shelf, inside a vertically scrolling page.
Future<ScrollController> _pump(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(800, 600)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final page = ScrollController();
  addTearDown(page.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildNoirTheme(Brightness.dark, Density.comfortable),
      home: NoirEffects(
        config: _effects,
        child: Scaffold(
          body: ListView(
            controller: page,
            children: [
              const SizedBox(height: 100),
              ShelfRow(
                title: 'Shelf',
                height: 100,
                itemExtent: 116,
                children: [
                  for (var i = 0; i < 20; i++)
                    SizedBox.square(dimension: 100, child: Text('item $i')),
                ],
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return page;
}

ScrollPosition _shelf(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(ShelfRow),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

double _arrowOpacity(WidgetTester tester, String tooltip) => tester
    .widget<GlassFade>(
      find.ancestor(
        of: find.byTooltip(tooltip),
        matching: find.byType(GlassFade),
      ),
    )
    .opacity;

ShelfEdgeFade _fade(WidgetTester tester) =>
    tester.widget<ShelfEdgeFade>(find.byType(ShelfEdgeFade));

Future<TestGesture> _hover(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(find.text('item 2')));
  await tester.pumpAndSettle();
  return mouse;
}

void main() {
  testWidgets('arrows fade in on hover and hide at their end', (tester) async {
    await _pump(tester);
    expect(_arrowOpacity(tester, 'Scroll left'), 0);
    expect(_arrowOpacity(tester, 'Scroll right'), 0, reason: 'not hovered');

    final mouse = await _hover(tester);
    expect(_arrowOpacity(tester, 'Scroll left'), 0, reason: 'at the start');
    expect(_arrowOpacity(tester, 'Scroll right'), 1);

    _shelf(tester).jumpTo(_shelf(tester).maxScrollExtent);
    await tester.pumpAndSettle();
    expect(_arrowOpacity(tester, 'Scroll left'), 1);
    expect(_arrowOpacity(tester, 'Scroll right'), 0, reason: 'at the end');

    await mouse.moveTo(const Offset(400, 590));
    await tester.pumpAndSettle();
    expect(_arrowOpacity(tester, 'Scroll left'), 0, reason: 'hover left');
  });

  testWidgets('an arrow pages by the visible width, eased, in whole items', (
    tester,
  ) async {
    await _pump(tester);
    await _hover(tester);
    await tester.tap(find.byTooltip('Scroll right'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final mid = _shelf(tester).pixels;
    expect(mid, greaterThan(0), reason: 'animates…');
    expect(mid, lessThan(812), reason: '…instead of jumping');
    await tester.pumpAndSettle();
    // 7 whole items of 116 px fit in 800 px.
    expect(_shelf(tester).pixels, 7 * 116);

    await tester.tap(find.byTooltip('Scroll left'));
    await tester.pumpAndSettle();
    expect(_shelf(tester).pixels, 0);
  });

  testWidgets('edges fade only where more content waits', (tester) async {
    await _pump(tester);
    expect(_fade(tester).start, 0);
    expect(_fade(tester).end, 1);

    _shelf(tester).jumpTo(ShelfRow.fade / 2);
    await tester.pump();
    expect(_fade(tester).start, 0.5);

    _shelf(tester).jumpTo(_shelf(tester).maxScrollExtent);
    await tester.pump();
    expect(_fade(tester).start, 1);
    expect(_fade(tester).end, 0);
  });

  testWidgets('a vertical wheel over the shelf scrolls the page', (
    tester,
  ) async {
    final page = await _pump(tester);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.text('item 2')),
        scrollDelta: const Offset(0, 100),
      ),
    );
    await tester.pumpAndSettle();
    expect(page.offset, 100);
    expect(_shelf(tester).pixels, 0);
  });

  testWidgets('Shift+wheel and horizontal wheels scroll the shelf', (
    tester,
  ) async {
    final page = await _pump(tester);
    final at = tester.getCenter(find.text('item 2'));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: at, scrollDelta: const Offset(120, 0)),
    );
    await tester.pumpAndSettle();
    expect(_shelf(tester).pixels, 120);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendEventToBinding(
      PointerScrollEvent(position: at, scrollDelta: const Offset(0, 100)),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(_shelf(tester).pixels, 220);
    expect(page.offset, 0);
  });

  testWidgets('touch drag scrolls the shelf; no scrollbar', (tester) async {
    await _pump(tester);
    await tester.drag(find.text('item 2'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(_shelf(tester).pixels, greaterThan(0));
    expect(
      find.descendant(
        of: find.byType(ShelfRow),
        matching: find.byType(RawScrollbar),
      ),
      findsNothing,
    );
  });
}

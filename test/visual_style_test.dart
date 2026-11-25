import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/ui/visual_style.dart';

double contrast(Color a, Color b) {
  final luminances = [a.computeLuminance(), b.computeLuminance()]..sort();
  return (luminances.last + .05) / (luminances.first + .05);
}

void main() {
  testWidgets('system bars follow the page theme without an AppBar', (
    tester,
  ) async {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: photoTreeTheme(brightness),
          builder: photoTreeAppBuilder,
          home: const Scaffold(body: Text('照片')),
        ),
      );
      await tester.pumpAndSettle();
      final style = tester
          .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
            find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
          )
          .value;
      final icons = brightness == Brightness.light
          ? Brightness.dark
          : Brightness.light;
      expect(style.statusBarIconBrightness, icons);
      expect(style.systemNavigationBarIconBrightness, icons);
      expect(style.statusBarBrightness, brightness);
      expect(style.statusBarColor, Colors.transparent);
      expect(
        style.systemNavigationBarColor,
        photoTreeTheme(brightness).scaffoldBackgroundColor,
      );
      expect(style.systemStatusBarContrastEnforced, false);
      expect(style.systemNavigationBarContrastEnforced, false);
      expect(photoTreeTheme(brightness).appBarTheme.systemOverlayStyle, style);
    }
  });

  test('glass text remains readable over both background extremes', () {
    for (final brightness in Brightness.values) {
      final theme = photoTreeTheme(brightness);
      final colors = theme.colorScheme;
      for (final backdrop in [Colors.black, Colors.white]) {
        final actual = Color.alphaBlend(
          colors.surface.withValues(alpha: .94),
          backdrop,
        );
        expect(contrast(colors.onSurface, actual), greaterThanOrEqualTo(4.5));
        expect(
          contrast(colors.onSurfaceVariant, actual),
          greaterThanOrEqualTo(4.5),
        );
        expect(contrast(colors.primary, actual), greaterThanOrEqualTo(3));
        expect(contrast(colors.error, actual), greaterThanOrEqualTo(4.5));
        final popup = Color.alphaBlend(theme.popupMenuTheme.color!, backdrop);
        expect(contrast(colors.onSurface, popup), greaterThanOrEqualTo(4.5));
        expect(contrast(colors.error, popup), greaterThanOrEqualTo(4.5));
      }
      expect(
        contrast(colors.onPrimaryContainer, colors.primaryContainer),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  test('sidebar auxiliary text passes at the lowest approved opacity', () {
    for (final brightness in Brightness.values) {
      final dark = brightness == Brightness.dark;
      final surface = dark
          ? PhotoTreeStyle.darkSurface
          : PhotoTreeStyle.lightSurface;
      final text = dark ? PhotoTreeStyle.darkText : PhotoTreeStyle.lightText;
      for (final backdrop in [Colors.black, Colors.white]) {
        expect(
          contrast(
            text,
            Color.alphaBlend(surface.withValues(alpha: .7), backdrop),
          ),
          greaterThanOrEqualTo(4.5),
        );
      }
    }
  });

  testWidgets(
    'sidebar opacity changes only its fill and disables opaque blur',
    (tester) async {
      Widget surface(double opacity, {bool reduced = false}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Center(
            child: GlassSurface(opacity: opacity, child: const Text('侧栏内容')),
          ),
        ),
      );
      for (final opacity in [.4, .55, .7, .86, .9, 1.0]) {
        await tester.pumpWidget(surface(opacity));
        expect(
          tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
          opacity < 1,
        );
        final fill = find.descendant(
          of: find.byType(BackdropFilter),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                (w.decoration as BoxDecoration).color != null,
          ),
        );
        final color =
            (tester.widget<DecoratedBox>(fill).decoration as BoxDecoration)
                .color!;
        expect(color.a, closeTo(opacity, .001));
        expect(
          find.ancestor(of: find.text('侧栏内容'), matching: find.byType(Opacity)),
          findsNothing,
        );
      }
      await tester.pumpWidget(surface(.7, reduced: true));
      expect(
        tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
        false,
      );
      expect(
        tester.widget<GlassSurface>(find.byType(GlassSurface)).opacity,
        .7,
      );
    },
  );

  testWidgets('glass clips to its bounds and keeps child state when disabled', (
    tester,
  ) async {
    Widget content({bool enabled = true, bool reduced = false}) => MaterialApp(
      theme: photoTreeTheme(Brightness.light),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Center(
          child: SizedBox(
            width: 180,
            height: 96,
            child: GlassSurface(enabled: enabled, child: const _Counter()),
          ),
        ),
      ),
    );
    await tester.pumpWidget(content());
    final filter = find.byType(BackdropFilter);
    final clip = find.ancestor(of: filter, matching: find.byType(ClipRRect));
    expect(tester.getSize(clip), const Size(180, 96));
    expect(tester.widget<BackdropFilter>(filter).enabled, true);
    await tester.tap(find.text('0'));
    await tester.pump();
    final state = tester.state(find.byType(_Counter));
    await tester.pumpWidget(content(enabled: false));
    expect(tester.widget<BackdropFilter>(filter).enabled, false);
    expect(tester.state(find.byType(_Counter)), same(state));
    expect(find.text('1'), findsOneWidget);
    await tester.pumpWidget(content(reduced: true));
    expect(tester.widget<BackdropFilter>(filter).enabled, false);
    expect(tester.state(find.byType(_Counter)), same(state));
    final fill = find.descendant(
      of: filter,
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox && (w.decoration as BoxDecoration).color != null,
      ),
    );
    final decoration =
        tester.widget<DecoratedBox>(fill).decoration as BoxDecoration;
    expect(decoration.color!.a, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('important content is opaque without filtering its background', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: photoTreeTheme(Brightness.dark),
        home: const Center(
          child: GlassSurface(
            highOpacity: true,
            child: Padding(padding: EdgeInsets.all(16), child: Text('永久删除')),
          ),
        ),
      ),
    );
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
      false,
    );
    final material = tester.element(find.text('永久删除'));
    expect(Theme.of(material).colorScheme.surface, PhotoTreeStyle.darkSurface);
    expect(tester.takeException(), isNull);
  });
}

class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int value = 0;
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => value++),
    child: Text('$value'),
  );
}

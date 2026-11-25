import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/ui/album_tree_row.dart';
import 'package:phototree/ui/visual_style.dart';

void main() {
  testWidgets('empty subtitle reserves no extra row and real text grows', (
    t,
  ) async {
    Future<void> show(double scale) => t.pumpWidget(
      MaterialApp(
        theme: photoTreeTheme(Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: const Scaffold(
            body: SizedBox(
              width: 220,
              child: Column(
                children: [
                  AlbumTreeRow(
                    key: ValueKey('null'),
                    leading: Icon(Icons.folder),
                    title: 'Album',
                  ),
                  AlbumTreeRow(
                    key: ValueKey('empty'),
                    leading: Icon(Icons.photo_album),
                    title: 'Album',
                    subtitle: '',
                  ),
                  AlbumTreeRow(
                    key: ValueKey('detail'),
                    leading: Icon(Icons.photo_album),
                    title: 'Album',
                    subtitle:
                        'A long actual directory path that needs wrapping',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await show(1);
    expect(t.getSize(find.byKey(const ValueKey('null'))).height, 48);
    expect(t.getSize(find.byKey(const ValueKey('empty'))).height, 48);
    expect(
      t.getSize(find.byKey(const ValueKey('detail'))).height,
      greaterThan(48),
    );
    await show(2);
    expect(
      t.getSize(find.byKey(const ValueKey('null'))).height,
      greaterThan(48),
    );
    expect(
      t.getSize(find.byKey(const ValueKey('empty'))).height,
      t.getSize(find.byKey(const ValueKey('null'))).height,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'compact rows stay 48 high without selection check or layout shift',
    (t) async {
      Future<void> show(
        bool selected, {
        double scale = 1,
        String title = 'Camera',
        bool reduce = false,
      }) => t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              textScaler: TextScaler.linear(scale),
              disableAnimations: reduce,
            ),
            child: Scaffold(
              body: SizedBox(
                width: 220,
                child: Column(
                  children: [
                    AlbumTreeRow(
                      key: const ValueKey('row'),
                      leading: const Icon(Icons.photo_album),
                      title: title,
                      selected: selected,
                      trailing: SizedBox(
                        width: 48,
                        height: 48,
                        child: IconButton(
                          onPressed: () {},
                          icon: const Icon(Icons.more_vert),
                        ),
                      ),
                      onTap: () {},
                    ),
                    const AlbumTreeRow(
                      key: ValueKey('next'),
                      leading: Icon(Icons.folder),
                      title: 'Next',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await show(false);
      final initial = t.getRect(find.byKey(const ValueKey('row')));
      expect(initial.height, 48);
      expect(
        t.getTopLeft(find.byKey(const ValueKey('next'))).dy,
        initial.bottom,
      );
      await show(true);
      await t.pump(const Duration(milliseconds: 60));
      expect(t.getRect(find.byKey(const ValueKey('row'))), initial);
      expect(find.byIcon(Icons.check), findsNothing);
      final animation = t.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(const ValueKey('row')),
          matching: find.byType(AnimatedContainer),
        ),
      );
      expect(animation.duration, const Duration(milliseconds: 120));
      for (final scale in [1.3, 2.0]) {
        for (final title in [
          'Long album name on boundary',
          '很长的相册名称用于检查选择切换时行高稳定',
        ]) {
          await show(false, scale: scale, title: title);
          await t.pumpAndSettle();
          final before = t.getRect(find.byKey(const ValueKey('row')));
          await show(true, scale: scale, title: title);
          await t.pump(const Duration(milliseconds: 60));
          expect(t.getRect(find.byKey(const ValueKey('row'))), before);
          await show(false, scale: scale, title: title);
          await t.pumpAndSettle();
          expect(t.getRect(find.byKey(const ValueKey('row'))), before);
          expect(t.takeException(), isNull);
        }
      }
      await show(true, reduce: true);
      expect(
        t
            .widget<AnimatedContainer>(
              find.descendant(
                of: find.byKey(const ValueKey('row')),
                matching: find.byType(AnimatedContainer),
              ),
            )
            .duration,
        Duration.zero,
      );
    },
  );
}

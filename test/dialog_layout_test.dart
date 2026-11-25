import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/ui/dialog_action_bar.dart';
import 'package:phototree/ui/visual_style.dart';

void main() {
  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets('confirmation keeps both actions visible at scale $scale', (
      t,
    ) async {
      t.view.physicalSize = const Size(320, 400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      var dismisses = 0, confirms = 0;
      await t.pumpWidget(
        MaterialApp(
          theme: photoTreeTheme(Brightness.dark),
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: PhotoTreeConfirmation(
              title: const Text('确认整体替换'),
              content: Text(List.filled(10, '不会创建目录、复制或修改媒体。').join()),
              dismissLabel: '取消',
              onDismiss: () => dismisses++,
              actionLabel: '确认替换',
              onAction: () => confirms++,
              destructive: true,
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull);
      final dismiss = t.getRect(find.widgetWithText(TextButton, '取消'));
      final confirm = t.getRect(find.widgetWithText(TextButton, '确认替换'));
      expect(dismiss.height, greaterThanOrEqualTo(48));
      expect(confirm.height, greaterThanOrEqualTo(48));
      expect(dismiss.bottom, lessThanOrEqualTo(400));
      if (scale >= 1.3) expect(confirm.bottom, lessThanOrEqualTo(dismiss.top));
      await t.tap(find.text('取消'));
      expect(dismisses, 1);
      expect(confirms, 0);
    });
  }
  testWidgets('secondary page title follows full large text without clipping', (
    t,
  ) async {
    t.view.physicalSize = const Size(320, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: photoTreeTheme(Brightness.light),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (c) => Scaffold(
            appBar: photoTreePageBar(c, title: '原应用与恢复的收藏'),
            body: const Text('内容'),
          ),
        ),
      ),
    );
    final text = t.widget<Text>(find.text('原应用与恢复的收藏'));
    expect(text.textScaler!.scale(20), 40);
    final title = t.getRect(find.text('原应用与恢复的收藏'));
    final bar = t.getRect(find.byType(AppBar));
    expect(title.top, greaterThanOrEqualTo(bar.top));
    expect(title.bottom, lessThanOrEqualTo(bar.bottom));
    expect(t.takeException(), isNull);
  });
}

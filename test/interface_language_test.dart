import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/storage/interface_language.dart';
import 'package:phototree/ui/language_setting.dart';
import 'package:phototree/ui/library_shell.dart';

import 'media_browser_test.dart' show photo;
import 'physical_operations_test.dart' show Harness;

class _Store implements InterfaceLanguageStore {
  InterfaceLanguage saved = InterfaceLanguage.system;
  bool unreadable = false;
  final writes = <InterfaceLanguage>[];
  Future<void> Function(InterfaceLanguage)? beforeWrite;
  @override
  Future<Directory> Function() get directory =>
      throw UnsupportedError('memory');
  @override
  Future<InterfaceLanguage> read() async {
    if (unreadable) throw const FormatException();
    return saved;
  }

  @override
  Future<void> write(InterfaceLanguage language) async {
    writes.add(language);
    await beforeWrite?.call(language);
    saved = language;
  }
}

void main() {
  test('private file survives reopen and a failed replacement', () async {
    final dir = await Directory.systemTemp.createTemp('phototree-language');
    addTearDown(() => dir.delete(recursive: true));
    InterfaceLanguageStore open() => InterfaceLanguageStore(() async => dir);
    expect(await open().read(), InterfaceLanguage.system);
    await open().write(InterfaceLanguage.chinese);
    final pending = Directory('${dir.path}/interface-language.pending');
    await pending.create();
    await expectLater(
      open().write(InterfaceLanguage.english),
      throwsA(isA<FileSystemException>()),
    );
    expect(await open().read(), InterfaceLanguage.chinese);
  });

  for (final code in ['zh', 'en', 'fr']) {
    testWidgets('first use follows primary system locale $code', (t) async {
      t.platformDispatcher.localesTestValue = [
        Locale(code),
        const Locale('en'),
      ];
      addTearDown(t.platformDispatcher.clearLocalesTestValue);
      final h = Harness();
      await h.init();
      addTearDown(h.dispose);
      await t.pumpWidget(
        InterfaceLanguageApp(
          store: _Store(),
          home: LibraryShell(browser: h.browser, organization: h.organization),
        ),
      );
      await t.pumpAndSettle();
      final en = code == 'en';
      await t.tap(find.byTooltip(en ? 'More' : '更多'));
      await t.pumpAndSettle();
      await t.tap(find.text(en ? 'More features' : '更多功能'));
      await t.pumpAndSettle();
      expect(find.text(en ? 'General' : '通用'), findsOneWidget);
      expect(find.text('跟随系统 / System default'), findsOneWidget);
      expect(find.byTooltip(en ? 'Back' : '返回'), findsOneWidget);
    });
  }

  testWidgets(
    'changes live on the pushed page and preserves the gallery, including names matching UI labels',
    (t) async {
      final h = Harness();
      h.media.items = [photo(7, directory: 'Pictures/收藏/')];
      await h.init();
      addTearDown(h.dispose);
      final store = _Store();
      final home = LibraryShell(
        browser: h.browser,
        organization: h.organization,
      );
      Future<void> start() async {
        await t.pumpWidget(InterfaceLanguageApp(store: store, home: home));
        await t.pumpAndSettle();
      }

      Future<void> choose(String label) async {
        await t.tap(find.text('语言 / Language'));
        await t.pumpAndSettle();
        await t.tap(find.text(label).last);
        await t.pumpAndSettle();
      }

      t.view.physicalSize = const Size(320, 640);
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.textScaleFactorTestValue = 2;
      t.platformDispatcher.localesTestValue = const [Locale('zh')];
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(t.platformDispatcher.clearLocalesTestValue);
      await start();
      final gallery = t.state(find.byType(LibraryShell));
      await t.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await t.pumpAndSettle();
      final album = find.byKey(ValueKey(h.browser.photos.single.albumKey));
      await t.scrollUntilVisible(
        album,
        160,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('album-management-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await t.tap(album);
      await t.pumpAndSettle();
      final groups = h.organization.snapshot;
      final photos = h.browser.photos.toList();
      await t.tap(find.byTooltip('更多'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('更多功能'));
      await t.tap(find.text('更多功能'));
      await t.pumpAndSettle();
      await choose('English');
      expect(find.text('General'), findsOneWidget);
      expect(find.byTooltip('Back'), findsOneWidget);
      await choose('简体中文');
      expect(find.text('通用'), findsOneWidget);
      await choose('English');
      t.platformDispatcher.localesTestValue = const [Locale('fr')];
      await t.pumpAndSettle();
      expect(find.text('General'), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();
      expect(t.state(find.byType(LibraryShell)), same(gallery));
      expect(h.organization.snapshot, same(groups));
      expect(h.browser.photos, photos);
      expect(find.text('收藏'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await start();
      expect(find.byTooltip('More'), findsOneWidget);
      await t.tap(find.byTooltip('More'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('More features'));
      await t.tap(find.text('More features'));
      await t.pumpAndSettle();
      await choose('跟随系统 / System default');
      expect(find.text('通用'), findsOneWidget);
      t.platformDispatcher.localesTestValue = const [Locale('en')];
      await t.pumpAndSettle();
      expect(find.text('General'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('read failure, overlapping choices and last successful write', (
    t,
  ) async {
    final store = _Store()..unreadable = true;
    const home = Scaffold(body: LanguageSetting());
    Future<void> start() async {
      await t.pumpWidget(InterfaceLanguageApp(store: store, home: home));
      await t.pumpAndSettle();
    }

    await start();
    expect(find.textContaining('Could not read'), findsOneWidget);
    final gate = Completer<void>();
    store.beforeWrite = (value) async {
      if (value == InterfaceLanguage.english) throw const FileSystemException();
      await gate.future;
    };
    final select = t.widget<LanguageScope>(find.byType(LanguageScope)).select;
    select(InterfaceLanguage.chinese);
    select(InterfaceLanguage.english);
    await t.pump();
    expect(store.writes, [InterfaceLanguage.chinese]);
    gate.complete();
    await t.pumpAndSettle();
    expect(store.writes, [
      InterfaceLanguage.chinese,
      InterfaceLanguage.english,
    ]);
    expect(find.text('简体中文'), findsOneWidget);
    expect(find.textContaining('语言设置保存失败'), findsOneWidget);
    store.unreadable = false;
    await t.pumpWidget(const SizedBox());
    await start();
    expect(find.text('简体中文'), findsOneWidget);
    expect(find.textContaining('保存失败'), findsNothing);
  });
}

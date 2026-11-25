import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/library/favorites.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/system_favorites.dart';
import 'package:phototree/ui/favorite_migration_page.dart';
import 'package:phototree/ui/photo_viewer.dart';

import 'library_views_test.dart' show MemoryFavorites;
import 'media_browser_test.dart' show FakeMedia;
import 'system_favorites_test.dart' show FakeSystem, item;

void main() {
  testWidgets(
    'private write failure cannot display a previous system success',
    (tester) async {
      final source = FakeMedia()..items = [item(1, false)];
      // Exercise the toolbar with a completed image failure, independently
      // of the engine's asynchronous bitmap decoder.
      source.image = () async => throw StateError('fixture image unavailable');
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final photo = source.items.first;
      final store = MemoryFavorites()
        ..migrationOutcomes[favoriteIdentity(photo, browser.libraryVersion)!] =
            'confirmed'
        ..failWrite = true;
      final favorites = Favorites(
        store,
        browser,
        system: FakeSystem()..requestsSupported = false,
      );
      await favorites.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhotoViewer(
              browser: browser,
              favorites: favorites,
              photos: browser.photos,
              initialKey: photo.key,
              origin: const Rect.fromLTWH(0, 0, 80, 80),
              locate: (_) async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加应用内收藏（系统互通未验证）'));
      await tester.pumpAndSettle();
      expect(find.text('收藏保存失败，请重试'), findsOneWidget);
      expect(find.text('已回读确认'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      favorites.dispose();
      browser.dispose();
    },
  );
  test(
    'favorite-only metadata refresh publishes state without image invalidation',
    () async {
      final source = FakeMedia()..items = [item(1, false)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final generation = browser.imageGeneration;
      source.items = [item(1, true)];
      await browser.refresh();
      expect(browser.photos.single.systemFavorite, true);
      expect(browser.imageGeneration, generation);
      browser.dispose();
    },
  );
  testWidgets(
    'pending migration offers only read-only reconciliation and never replays',
    (tester) async {
      final source = FakeMedia()..items = [item(1, false), item(2, false)];
      source.image = () async => throw StateError('fixture image unavailable');
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final ids = {
        for (final photo in source.items)
          favoriteIdentity(photo, browser.libraryVersion)!,
      };
      final store = MemoryFavorites()..records.addAll(ids);
      final system = FakeSystem();
      system.action = (_, _) async {
        system.pendingRequest = true;
        return const SystemFavoriteResult(
          SystemFavoriteOutcome.unknown,
          pending: true,
        );
      };
      final favorites = Favorites(store, browser, system: system);
      await favorites.load();
      await favorites.migrateSelected(ids);
      expect(system.calls, 1);
      expect(store.records, ids);
      await tester.pumpWidget(
        MaterialApp(home: FavoriteMigrationPage(favorites: favorites)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
            .onChanged,
        isNull,
      );
      await tester.tap(find.text('核对未决收藏请求'));
      await tester.pumpAndSettle();
      expect(favorites.systemRequestPending, true);
      expect(system.calls, 1);
      system.pendingRequest = false;
      await tester.tap(find.text('核对未决收藏请求'));
      await tester.pumpAndSettle();
      expect(favorites.systemRequestPending, false);
      expect(system.calls, 1);
      expect(find.textContaining('上次操作：结果待核验'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
            .onChanged,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      favorites.dispose();
      browser.dispose();
    },
  );

  for (final verified in [false, true]) {
    testWidgets(
      'migration selection requires verification=$verified and confirmation',
      (tester) async {
        final source = FakeMedia()..items = [item(1, false), item(2, false)];
        source.image = () async => base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jw1kAAAAASUVORK5CYII=',
        );
        final browser = PhotoBrowser(source);
        await browser.refresh();
        final ids = {
          for (final photo in source.items)
            favoriteIdentity(photo, browser.libraryVersion)!,
        };
        final store = MemoryFavorites()..records.addAll(ids);
        final system = FakeSystem()..requestsSupported = verified;
        final favorites = Favorites(store, browser, system: system);
        await favorites.load();
        await tester.pumpWidget(
          MaterialApp(home: FavoriteMigrationPage(favorites: favorites)),
        );
        await tester.pumpAndSettle();
        final checkbox = tester.widget<CheckboxListTile>(
          find.byType(CheckboxListTile).first,
        );
        expect(checkbox.onChanged != null, verified);
        if (verified) {
          await tester.tap(find.text('照片 1'));
          await tester.pump();
          await tester.tap(find.text('将所选 1 项添加到系统收藏'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(system.calls, 0);
          system.action = (photo, value) async {
            expect(photo.id, 1);
            expect(value, true);
            source.items = [item(1, true), item(2, false)];
            return const SystemFavoriteResult(
              SystemFavoriteOutcome.confirmed,
              value: true,
            );
          };
          await tester.tap(find.text('将所选 1 项添加到系统收藏'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('继续'));
          await tester.pumpAndSettle();
          expect(system.calls, 1);
          expect(store.records, ids);
          expect(find.textContaining('上次操作：已回读确认'), findsOneWidget);
          source.items = [item(1, false), item(2, false)];
          await browser.refresh();
          await tester.pumpAndSettle();
          expect(find.text('当前未收藏\n上次操作：已回读确认'), findsOneWidget);
        } else {
          expect(find.textContaining('系统相册互通尚未验证'), findsOneWidget);
          expect(system.calls, 0);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        favorites.dispose();
        browser.dispose();
      },
    );
  }
}

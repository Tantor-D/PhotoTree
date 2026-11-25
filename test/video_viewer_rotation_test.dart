import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/ui/photo_viewer.dart';

import 'media_browser_test.dart' show FakeMedia;
import 'video_playback_test.dart' show Player;

// Mirrors the app observer, registered before the viewer observer.
class BrowserLifecycle with WidgetsBindingObserver {
  BrowserLifecycle(this.browser);
  final PhotoBrowser browser;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) browser.suspend();
    if (state == AppLifecycleState.resumed) unawaited(browser.refresh());
  }
}

void main() {
  for (final scenario in [
    'rotation',
    'metrics first',
    'stale metrics',
    'paused rotation',
    'changed identity',
    'late background',
    'background rotation',
    'focus only',
  ]) {
    testWidgets('$scenario preserves only foreground rotation play intent', (
      t,
    ) async {
      const video = Photo(
        id: 1,
        directory: 'Pictures/V/',
        kind: MediaKind.video,
      );
      final source = FakeMedia()
        ..items = [video]
        ..image = () async => base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
        );
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final lifecycle = BrowserLifecycle(browser);
      t.binding.addObserver(lifecycle);
      t.view.physicalSize = const Size(400, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(() {
        t.binding.removeObserver(lifecycle);
        browser.dispose();
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
      });
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final players = <Player>[];
      final lateInit = Completer<void>();
      await t.pumpWidget(
        MaterialApp(
          home: PhotoViewer(
            browser: browser,
            photos: [video],
            initialKey: video.key,
            origin: const Rect.fromLTWH(0, 0, 100, 100),
            locate: (_) async => null,
            createVideoController: (_) {
              final p = Player();
              if (scenario == 'late background' && players.length == 1) {
                p.initWait = lateInit;
              }
              players.add(p);
              return p;
            },
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('播放视频'));
      await t.pumpAndSettle();
      expect(players.last.value.isPlaying, true);
      await players.last.seekTo(const Duration(seconds: 12));
      if (scenario == 'paused rotation') {
        await t.tap(find.byTooltip('暂停视频'));
        await t.pumpAndSettle();
      }
      if (scenario == 'metrics first' || scenario == 'stale metrics') {
        t.view.physicalSize = const Size(800, 400);
        await t.pump(
          scenario == 'stale metrics'
              ? const Duration(seconds: 1)
              : const Duration(milliseconds: 60),
        );
      }
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      if (scenario == 'changed identity') {
        source.items = [
          const Photo(
            id: 1,
            directory: 'Pictures/V/',
            kind: MediaKind.video,
            addedSeconds: 99,
          ),
        ];
      }
      if (scenario == 'background rotation') {
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      }
      if (scenario != 'focus only') t.view.physicalSize = const Size(800, 400);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      if (scenario == 'late background') {
        await t.pump();
        expect(players.length, 2);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        lateInit.complete();
        await t.pump();
        expect(players.every((p) => !p.value.isPlaying), true);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
      await t.pumpAndSettle();
      expect(
        players.last.value.position,
        scenario == 'changed identity'
            ? Duration.zero
            : const Duration(seconds: 12),
      );
      expect(
        players.last.value.isPlaying,
        scenario == 'rotation' || scenario == 'metrics first',
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
}

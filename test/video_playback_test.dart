import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/ui/video_playback.dart';

import 'media_browser_test.dart' show FakeMedia;

class Player extends VideoPlayerController {
  Player() : super.networkUrl(Uri.parse('https://invalid.test/video'));
  Completer<void>? initWait, releaseWait, seekWait;
  bool released = false, fail = false;
  Size videoSize = const Size(640, 360);
  bool trackSupport = true;
  int trackQueries = 0;
  List<VideoTrack> tracks = const [VideoTrack(id: 'video', isSelected: true)];
  Completer<List<VideoTrack>>? tracksWait;
  int plays = 0, pauses = 0;
  @override
  Future<void> initialize() async {
    await initWait?.future;
    if (released) return;
    if (fail) throw StateError('unsupported');
    value = value.copyWith(
      isInitialized: true,
      duration: const Duration(seconds: 90),
      size: videoSize,
    );
  }

  @override
  bool isVideoTrackSupportAvailable() => trackSupport;

  @override
  Future<List<VideoTrack>> getVideoTracks() async {
    trackQueries++;
    return tracksWait == null ? tracks : await tracksWait!.future;
  }

  @override
  Future<void> play() async {
    if (released) return;
    plays++;
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    if (released) return;
    pauses++;
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> setVolume(double volume) async {
    if (!released) value = value.copyWith(volume: volume);
  }

  @override
  Future<void> seekTo(Duration position) async {
    await seekWait?.future;
    if (!released) value = value.copyWith(position: position);
  }

  @override
  Future<void> dispose() async {
    await releaseWait?.future;
    released = true;
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const video = Photo(id: 1, directory: 'Pictures/V/', kind: MediaKind.video);
  const next = Photo(id: 2, directory: 'Pictures/V/', kind: MediaKind.video);
  Future<void> tick() => Future<void>.delayed(Duration.zero);

  test('initialized container without a video track is not playable', () async {
    final source = FakeMedia()..items = [video];
    final player = Player()
      ..videoSize = Size.zero
      ..tracks = [];
    final playback = VideoPlayback(source, createController: (_) => player);
    addTearDown(playback.dispose);
    await playback.open(video, 'v');
    expect(playback.error, '不支持或无法播放');
    expect(playback.ready, false);
    await playback.toggle();
    expect(player.plays, 0);
    expect(source.items.single, video);
  });

  test('missing size alone does not reject an available video track', () async {
    final player = Player()..videoSize = Size.zero;
    final playback = VideoPlayback(
      FakeMedia(),
      createController: (_) => player,
    );
    addTearDown(playback.dispose);
    await playback.open(video, 'v');
    expect(player.trackQueries, 1);
    expect(playback.ready, true);
    await playback.toggle();
    expect(player.plays, 1);
  });

  test(
    'sized video and unsupported track introspection skip track query',
    () async {
      for (final player in [
        Player(),
        Player()
          ..videoSize = Size.zero
          ..trackSupport = false,
      ]) {
        final playback = VideoPlayback(
          FakeMedia(),
          createController: (_) => player,
        );
        await playback.open(video, 'v');
        expect(playback.ready, true);
        expect(player.trackQueries, 0);
        playback.dispose();
      }
    },
  );

  test('late empty track result cannot fail a newer video', () async {
    final first = Player()
      ..videoSize = Size.zero
      ..tracksWait = Completer();
    final second = Player();
    var count = 0;
    final playback = VideoPlayback(
      FakeMedia(),
      createController: (_) => ++count == 1 ? first : second,
    );
    addTearDown(playback.dispose);
    final opening = playback.open(video, 'v');
    await tick();
    expect(first.trackQueries, 1);
    await playback.open(next, 'v');
    first.tracksWait!.complete([]);
    await opening;
    expect(first.released, true);
    expect(playback.controller, second);
    expect(playback.error, isNull);
  });

  test('starts paused and audible; suspension releases and returns paused at same position', () async {
    final players = <Player>[];
    final playback = VideoPlayback(
      FakeMedia(),
      createController: (_) {
        final p = Player();
        players.add(p);
        return p;
      },
    );
    addTearDown(playback.dispose);
    await playback.open(video, 'v');
    final first = players.single;
    expect(first.plays, 0);
    expect(first.value.volume, 1);
    await playback.toggle();
    await first.seekTo(const Duration(seconds: 15));
    await playback.stop();
    expect(first.released, true);
    expect(first.value.isPlaying, false);
    await playback.open(video, 'v');
    expect(players.last.value.position, const Duration(seconds: 15));
    expect(players.last.plays, 0);
    await playback.toggleMute();
    expect(players.last.value.volume, 0);
    await playback.open(next, 'v');
    expect(players.last.value.position, Duration.zero);
    expect(players.last.value.volume, 1);
    expect(players.where((p) => !p.released).length, 1);
  });

  test('late initialization cannot revive prior video; new controller waits for disposal', () async {
    final first = Player()
      ..initWait = Completer()
      ..releaseWait = Completer();
    final second = Player();
    var count = 0;
    final playback = VideoPlayback(
      FakeMedia(),
      createController: (_) => ++count == 1 ? first : second,
    );
    addTearDown(playback.dispose);
    final opening = playback.open(video, 'v');
    await tick();
    final switching = playback.open(next, 'v');
    await tick();
    expect(count, 1);
    first.releaseWait!.complete();
    await switching;
    first.initWait!.complete();
    await opening;
    expect(playback.controller, second);
    expect(first.released, true);
    expect(first.plays, 0);
    expect(second.plays, 0);
  });

  test(
    'seek resumes only uninterrupted playing item, never after background stop',
    () async {
      final first = Player();
      final playback = VideoPlayback(
        FakeMedia(),
        createController: (_) => first,
      );
      addTearDown(playback.dispose);
      await playback.open(video, 'v');
      playback.beginSeek();
      await playback.seek(const Duration(seconds: 2));
      expect(first.plays, 0);
      await playback.toggle();
      playback.beginSeek();
      await playback.seek(const Duration(seconds: 4));
      expect(first.value.isPlaying, true);
      final plays = first.plays;
      playback.beginSeek();
      first.seekWait = Completer();
      final seeking = playback.seek(const Duration(seconds: 8));
      await playback.stop();
      first.seekWait!.complete();
      await seeking;
      expect(first.plays, plays);
      expect(first.released, true);
    },
  );

  test(
    'unsupported player remains an explicit failure without media removal',
    () async {
      final source = FakeMedia()..items = [video];
      final playback = VideoPlayback(
        source,
        createController: (_) => Player()..fail = true,
      );
      addTearDown(playback.dispose);
      await playback.open(video, 'v');
      expect(playback.error, '不支持或无法播放');
      expect(playback.ready, false);
      expect(source.items.single, video);
    },
  );

  test(
    'late seek cannot override a second drag or newer pause intent',
    () async {
      final first = Player();
      final playback = VideoPlayback(
        FakeMedia(),
        createController: (_) => first,
      );
      addTearDown(playback.dispose);
      await playback.open(video, 'v');
      await playback.toggle();
      playback.beginSeek();
      final waiting = Completer<void>();
      first.seekWait = waiting;
      final old = playback.seek(const Duration(seconds: 8));
      await tick();
      final plays = first.plays;
      playback.beginSeek();
      final recent = playback.seek(const Duration(seconds: 20));
      first.seekWait = null;
      waiting.complete();
      await Future.wait([old, recent]);
      expect(first.value.position, const Duration(seconds: 20));
      expect(first.plays, plays);
      expect(first.value.isPlaying, false);

      await playback.toggle();
      playback.beginSeek();
      first.seekWait = Completer<void>();
      final late = playback.seek(const Duration(seconds: 30));
      await tick();
      await playback.toggle();
      await playback.toggle();
      final afterPause = first.plays;
      first.seekWait!.complete();
      await late;
      expect(first.plays, afterPause);
      expect(first.value.isPlaying, false);
    },
  );

  test(
    'duration formatting distinguishes unknown, zero, minutes and hours',
    () {
      expect(mediaDuration(null), '时长未知');
      expect(mediaDuration(-1), '时长未知');
      expect(mediaDuration(0), '00:00');
      expect(mediaDuration(62000), '01:02');
      expect(mediaDuration(3661000), '1:01:01');
    },
  );
}

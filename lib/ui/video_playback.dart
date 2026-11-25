import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../library/favorites.dart';
import '../media/android_video_player.dart';
import '../media/media_source.dart';

// Viewer-local ownership: at most one controller, even across late initialize
// completions. Switching or suspending invalidates every pending play/seek.
class VideoPlayback extends ChangeNotifier {
  VideoPlayback(this.source, {this.createController = androidVideoController});
  final MediaSource source;
  final VideoPlayerController Function(Uri) createController;
  VideoPlayerController? _controller;
  VideoPlayerController? get controller => ready ? _controller : null;
  bool get ready =>
      _controller?.value.isInitialized == true && !loading && error == null;
  bool loading = false, muted = false, _disposed = false, _resumeSeek = false;
  String? error, _identity;
  Duration _savedPosition = Duration.zero;
  int _epoch = 0;
  int _intent = 0, _seekTicket = 0;
  Future<void> _seekTail = Future.value();
  Future<void> _release = Future.value();
  bool _current(int epoch) => !_disposed && epoch == _epoch;
  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void _changed() {
    if (_controller?.value.hasError == true) error = '不支持或无法播放';
    _publish();
  }

  Future<void> open(Photo photo, String version) async {
    final identity = favoriteIdentity(photo, version);
    if (identity == _identity && (_controller != null || loading)) return;
    final previous = _identity;
    final released = stop();
    _identity = identity;
    if (previous != identity) {
      _savedPosition = Duration.zero;
      muted = false;
    }
    final epoch = _epoch;
    loading = true;
    error = null;
    _publish();
    try {
      await released;
      if (!_current(epoch)) return;
      final uri = await source.playbackUri(photo, version);
      if (!_current(epoch)) return;
      final controller = createController(uri);
      _controller = controller;
      controller.addListener(_changed);
      await controller.initialize();
      if (!_current(epoch)) return;
      // A container can initialize even when the decoder ignored its video
      // track. Do not present its duration as a successfully playable video.
      if (controller.value.size.isEmpty &&
          controller.isVideoTrackSupportAvailable()) {
        final tracks = await controller.getVideoTracks();
        if (!_current(epoch)) return;
        if (tracks.isEmpty) throw StateError('No playable video track');
      }
      await controller.setVolume(muted ? 0 : 1);
      if (!_current(epoch)) return;
      if (_savedPosition > Duration.zero) {
        await controller.seekTo(_savedPosition);
      }
      if (!_current(epoch)) return;
      loading = false;
      _publish();
    } catch (_) {
      if (_current(epoch)) {
        loading = false;
        error = '不支持或无法播放';
        _publish();
      }
    }
  }

  Future<void> toggle() async {
    final c = controller, epoch = _epoch;
    final intent = ++_intent;
    if (c == null) return;
    try {
      if (c.value.isPlaying) {
        await c.pause();
      } else {
        if (c.value.position >= c.value.duration) await c.seekTo(Duration.zero);
        if (_current(epoch) && intent == _intent) await c.play();
        if (!_current(epoch)) await c.pause();
      }
    } catch (_) {
      if (_current(epoch)) {
        error = '不支持或无法播放';
        _publish();
      }
    }
  }

  Future<void> toggleMute() async {
    final c = controller;
    if (c == null) return;
    muted = !muted;
    try {
      await c.setVolume(muted ? 0 : 1);
    } catch (_) {}
    _publish();
  }

  void beginSeek() {
    _intent++;
    final c = controller;
    _resumeSeek = c?.value.isPlaying == true;
    if (c != null) unawaited(c.pause().catchError((Object _) {}));
  }

  Future<void> seek(Duration position) async {
    final c = controller, epoch = _epoch, resume = _resumeSeek;
    final intent = ++_intent, ticket = ++_seekTicket;
    _resumeSeek = false;
    if (c == null) return;
    final task = _seekTail.then((_) async {
      if (!_current(epoch) || ticket != _seekTicket) return;
      try {
        await c.seekTo(position);
        if (_current(epoch) && intent == _intent && resume) await c.play();
        if (!_current(epoch)) await c.pause();
      } catch (_) {
        if (_current(epoch) && ticket == _seekTicket) {
          error = '不支持或无法播放';
          _publish();
        }
      }
    });
    _seekTail = task;
    await task;
  }

  Future<void> stop({bool forget = false}) {
    _epoch++;
    _intent++;
    _seekTicket++;
    _seekTail = Future.value();
    _resumeSeek = false;
    loading = false;
    final old = _controller;
    _controller = null;
    if (old != null) {
      if (old.value.isInitialized) _savedPosition = old.value.position;
      old.removeListener(_changed);
      // Pause immediately, then serialize disposal before any new controller.
      final paused = old.pause().catchError((Object _) {});
      _release = _release.then((_) async {
        await paused;
        try {
          await old.dispose();
        } catch (_) {}
      });
    }
    if (forget) {
      _identity = null;
      _savedPosition = Duration.zero;
      muted = false;
    }
    return _release;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}

String mediaDuration(int? milliseconds) {
  if (milliseconds == null || milliseconds < 0) return '时长未知';
  final seconds = milliseconds ~/ 1000;
  String two(int n) => n.toString().padLeft(2, '0');
  return seconds >= 3600
      ? '${seconds ~/ 3600}:${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}'
      : '${two(seconds ~/ 60)}:${two(seconds % 60)}';
}

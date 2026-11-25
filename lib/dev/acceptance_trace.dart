import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

// Opt-in profile instrumentation. No product state, substitute media or timing
// changes. Read raw samples through the VM service; normal APKs do not enable it.
const acceptanceTraceEnabled = bool.fromEnvironment('PHOTOTREE_TRACE');

final acceptanceTrace = AcceptanceTrace();

void traceThumbnail(String key, BuildContext context) {
  if (!acceptanceTraceEnabled) return;
  final stamp =
      SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
  SchedulerBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final screen = (Offset.zero & MediaQuery.sizeOf(context)).inflate(0.01);
    if (!screen.contains(rect.topLeft) || !screen.contains(rect.bottomRight)) {
      return;
    }
    acceptanceTrace.thumbnail(key, stamp, rect);
  });
}

class AcceptanceTrace {
  final _frames = <Map<String, Object>>[];
  final _events = <Map<String, Object>>[];
  final _thumbnails = <String, Map<String, Object>>{};
  List<String> _expectedKeys = [];
  void expectStartupKeys(Iterable<String> keys) {
    if (_expectedKeys.isEmpty) _expectedKeys = keys.take(12).toList();
  }

  Map<String, Object?>? _clock;
  void thumbnail(String key, int stamp, Rect rect) {
    if (!_expectedKeys.contains(key) || _thumbnails.containsKey(key)) return;
    final value = {
      'key': key,
      'frameStampUs': stamp,
      'rect': [rect.left, rect.top, rect.right, rect.bottom],
    };
    _thumbnails[key] = value;
    developer.Timeline.instantSync('PhotoTree.thumbnail', arguments: value);
    // One conservative confirmation frame after all twelve decoded children
    // enter the static tree. This also drains a final batched timing callback.
    if (_thumbnails.length == 12) SchedulerBinding.instance.scheduleFrame();
  }

  int? _start = 0, _end;
  bool _overflow = false;
  Future<void> start() async {
    SchedulerBinding.instance.addTimingsCallback(_timings);
    developer.registerExtension('ext.phototree.measure', (_, params) async {
      final action = params['action'];
      if (action == 'start') {
        _frames.clear();
        _events.clear();
        _overflow = false;
        _start = developer.Timeline.now;
        _end = null;
        _mark('start');
      } else if (action == 'inject') {
        _mark('instrument-check-100ms');
        SchedulerBinding.instance.scheduleFrameCallback((_) {
          final watch = Stopwatch()..start();
          while (watch.elapsedMilliseconds < 100) {
            /* Intentional instrument check only. */
          }
        });
      } else if (action == 'mark') {
        _mark(params['name'] ?? 'unnamed');
      } else if (action == 'stop') {
        _end = developer.Timeline.now;
        _mark('stop');
      }
      // Fetch after stop and a callback-drain delay; no samples synthesized.
      return developer.ServiceExtensionResponse.result(
        jsonEncode({
          'startUs': _start,
          'endUs': _end,
          'overflow': _overflow,
          'events': _events,
          'frames': _frames,
          'clock': _clock,
          'startupThumbnails': _thumbnails.values.toList(),
          'expectedStartupKeys': _expectedKeys,
        }),
      );
    });
    // Bracket the native clock reading to bound bridge uncertainty. Raw values
    // are retained for actual device calibration; no assumed host clock match.
    for (var i = 0; i < 5; i++) {
      final before = developer.Timeline.now;
      final native = await const MethodChannel('io.github.tantor_d.phototree/metadata')
          .invokeMapMethod<String, Object>('acceptanceClock');
      final after = developer.Timeline.now;
      final old = _clock;
      if (old == null ||
          after - before <
              (old['dartAfterUs'] as int) - (old['dartBeforeUs'] as int)) {
        _clock = {'dartBeforeUs': before, 'dartAfterUs': after, ...?native};
      }
    }
    developer.Timeline.instantSync('PhotoTree.clock', arguments: _clock);
  }

  void _mark(String name) {
    final now = developer.Timeline.now;
    _events.add({'name': name, 'timeUs': now});
    developer.Timeline.instantSync('PhotoTree.$name');
  }

  void _timings(List<FrameTiming> timings) {
    if (_start == null) return;
    for (final frame in timings) {
      final vsync = frame.timestampInMicroseconds(FramePhase.vsyncStart);
      if (vsync < _start! || (_end != null && vsync > _end!)) continue;
      if (_frames.length >= 20000) {
        _overflow = true;
        continue;
      }
      _frames.add({
        'number': frame.frameNumber,
        'vsyncUs': vsync,
        'buildStartUs': frame.timestampInMicroseconds(FramePhase.buildStart),
        'rasterFinishUs': frame.timestampInMicroseconds(
          FramePhase.rasterFinish,
        ),
        'buildUs': frame.buildDuration.inMicroseconds,
        'rasterUs': frame.rasterDuration.inMicroseconds,
        'totalUs': frame.totalSpan.inMicroseconds,
      });
    }
  }
}

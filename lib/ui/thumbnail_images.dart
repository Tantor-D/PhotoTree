import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../media/browser.dart';
import '../media/media_source.dart';

enum ThumbnailQuality { preview, detail }

// Value identity, independent of encoded buffers and widget lifetime. The
// browser instance isolates sessions; imageGeneration isolates content changes.
@immutable
class ThumbnailKey {
  ThumbnailKey(
    this.browser,
    this.generation,
    Photo photo,
    this.pixels,
    this.quality,
  ) : media = (
        photo.key,
        photo.directory,
        photo.takenMs,
        photo.addedSeconds,
        photo.width,
        photo.height,
        photo.durationMs,
      );
  final PhotoBrowser browser;
  final int generation, pixels;
  final ThumbnailQuality quality;
  final (String, String, int, int, int, int, int?) media;
  // All grid images use aspect-preserving decode and centered cover rendering.
  final String crop = 'fit-center-cover';
  @override
  bool operator ==(Object other) =>
      other is ThumbnailKey &&
      identical(browser, other.browser) &&
      generation == other.generation &&
      media == other.media &&
      pixels == other.pixels &&
      quality == other.quality &&
      crop == other.crop;
  @override
  int get hashCode =>
      Object.hash(browser, generation, media, pixels, quality, crop);
}

/// Narrow grid provider. Flutter looks up this key before invoking loadImage;
/// a compressed-cache eviction cannot hide an existing decoded result.
class ThumbnailProvider extends ImageProvider<ThumbnailKey> {
  ThumbnailProvider(this.images, this.photo, this.key);
  final ThumbnailImages images;
  final Photo photo;
  final ThumbnailKey key;
  @override
  Future<ThumbnailKey> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(key);
  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    ThumbnailKey key,
    ImageErrorListener handleError,
  ) {
    if (!images.allowed(photo, key)) {
      handleError(const MediaFailure(MediaFailureKind.stale), null);
      return;
    }
    super.resolveStreamForKey(configuration, stream, key, handleError);
  }

  @override
  ImageStreamCompleter loadImage(
    ThumbnailKey key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(images._load(photo, key));
}

class _Preview {
  _Preview(this.image);
  final ui.Image image;
  int references = 0;
  bool retained = true;
  int get bytes => image.width * image.height * 4;
}

/// The tile owns this handle, including the render object's clone until its
/// next paint/detach. Release is delayed to the end of that frame. Retired pool
/// entries remain counted until the last tile/render reference is released.
class ThumbnailFrame {
  ThumbnailFrame(this.image, this.quality, this._release);
  final ui.Image image;
  final ThumbnailQuality quality;
  final VoidCallback _release;
  void dispose() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      image.dispose();
      _release();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }
}

class _VisibleImage {
  _VisibleImage(this.photo, this.pixels);
  final Photo photo;
  final int pixels;
  ImageStream? stream;
  ImageStreamListener? listener;
  ImageInfo? detail;
  Object? error;
  ThumbnailQuality? errorQuality;
  void dispose() {
    if (stream != null && listener != null) stream!.removeListener(listener!);
    detail?.dispose();
    detail = null;
  }
}

class _Load {
  _Load(this.photo, this.key, this.reload);
  final Photo photo;
  final ThumbnailKey key;
  final bool reload;
  ThumbnailWork? startedWork;
  final result = Completer<ImageInfo>();
}

/// One grid-image owner per app/browser session, explicitly supplied at the
/// composition point. No media/plugin calls and no second library snapshot.
class ThumbnailImages with WidgetsBindingObserver {
  ThumbnailImages(this.browser) {
    _generation = browser.imageGeneration;
    browser.addListener(_browserChanged);
    WidgetsBinding.instance.addObserver(this);
  }
  final PhotoBrowser browser;
  late int _generation;
  bool _disposed = false;
  final _previews = <ThumbnailKey, _Preview>{};
  final _retired = <_Preview>{};
  final _recent = <String>{};
  final _visible = <String, _VisibleImage>{};
  // Mounted non-grid tiles (album covers and pickers) own independent demand.
  // Their images use the existing Flutter cache, never the grid preview pool.
  final _covers = <Object, _VisibleImage>{};
  final _ahead = <String, Photo>{};
  List<Photo> _aheadWindow = const [];
  bool _prefetchExpanded = false, _continuousMotion = false;
  int? _prefetchDirection;
  final _listeners = <String, Set<VoidCallback>>{};
  final _loads = <ThumbnailKey, _Load>{};
  final _queue = <_Load>[];
  final _retry = <ThumbnailKey>{};
  int _active = 0, _reading = 0, _decoding = 0, _speculative = 0, _detail = 0;
  int maxActive = 0, maxReading = 0, maxDecoding = 0, decodeCount = 0;
  int _previewPixels = 0;
  bool _settled = false, _pumpScheduled = false;
  Timer? _settle;
  Object? _windowOwner;
  final _visibleReady = ValueNotifier<bool>(false);
  bool _readinessScheduled = false;

  /// Current visible target-quality pixels, derived from this owner's handles.
  /// Presentation decisions and restoration timers belong to the grid.
  ValueListenable<bool> get visibleDetailsReady => _visibleReady;

  void _publishReadiness() {
    if (_disposed || _readinessScheduled) return;
    _readinessScheduled = true;
    scheduleMicrotask(() {
      _readinessScheduled = false;
      if (_disposed) return;
      _visibleReady.value =
          _visible.isNotEmpty &&
          _visible.values.every(
            (item) =>
                allowed(
                  item.photo,
                  key(item.photo, item.pixels, ThumbnailQuality.detail),
                ) &&
                !_needsDetail(item),
          );
    });
  }

  int get previewEntries => _previews.length + _retired.length;
  int get previewBytes => _previewPixels;
  int get queued => _queue.length;
  int get active => _active;
  int get recentCount => _recent.length;
  int get speculativeEntries => _previews.keys
      .where(
        (k) =>
            !_recent.contains(k.media.$1) && !_visible.containsKey(k.media.$1),
      )
      .length;
  bool capacityLimited = false;

  ThumbnailKey key(Photo photo, int pixels, ThumbnailQuality quality) =>
      ThumbnailKey(browser, browser.imageGeneration, photo, pixels, quality);
  bool allowed(Photo photo, ThumbnailKey key) =>
      !_disposed &&
      identical(key.browser, browser) &&
      browser.canDisplayImage(photo, key.generation);

  void addImageListener(String key, VoidCallback listener) =>
      (_listeners[key] ??= {}).add(listener);
  void removeImageListener(String key, VoidCallback listener) {
    _listeners[key]?.remove(listener);
    if (_listeners[key]?.isEmpty == true) _listeners.remove(key);
  }

  void _notify(String key) {
    _publishReadiness();
    void send() {
      for (final listener in _listeners[key]?.toList() ?? <VoidCallback>[]) {
        listener();
      }
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => send());
    } else {
      send();
    }
  }

  void attachCover(Object owner, Photo photo, int pixels) {
    final old = _covers[owner];
    if (old != null &&
        key(old.photo, old.pixels, ThumbnailQuality.detail) ==
            key(photo, pixels, ThumbnailQuality.detail)) {
      return;
    }
    final retained =
        old != null &&
            key(old.photo, pixels, ThumbnailQuality.detail) ==
                key(photo, pixels, ThumbnailQuality.detail)
        ? old.detail?.clone()
        : null;
    old?.dispose();
    _covers[owner] = _VisibleImage(photo, pixels)..detail = retained;
    _cancelUnneeded();
    _ensureWindow();
  }

  void detachCover(Object owner) {
    _covers.remove(owner)?.dispose();
    _cancelUnneeded();
  }

  bool _currentItem(_VisibleImage item) =>
      identical(_visible[item.photo.key], item) || _covers.containsValue(item);

  bool _coverNeeded(_Load job) => _covers.values.any(
    (item) => key(item.photo, item.pixels, ThumbnailQuality.detail) == job.key,
  );

  void scrollActivity() {
    final wasSettled = _settled;
    _settled = false;
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 150), _onSettled);
    if (wasSettled) _cancelUnneeded();
  }

  // A stop withdraws the extra lane immediately, without advancing the
  // existing 150ms detail timer or pretending active source work was cancelled.
  void scrollStopped() {
    _continuousMotion = false;
    browser.reprioritizeImages();
  }

  bool get _mayUseSecondSpeculative =>
      _continuousMotion &&
      !_settled &&
      _prefetchExpanded &&
      _visible.isNotEmpty &&
      _visible.values.every(
        (item) =>
            item.detail != null ||
            _previews.containsKey(
              key(item.photo, 128, ThumbnailQuality.preview),
            ),
      ) &&
      _covers.values.every((item) => item.detail != null) &&
      !_queue.any(
        (job) => _needed(job) && _work(job) != ThumbnailWork.speculative,
      );

  /// Only actual visible identities enter recency. Layout cache children do not.
  void updateWindow(
    Object owner,
    List<Photo> visible,
    List<Photo> ahead,
    int pixels, {
    bool moving = false,
    int initialPrefetch = 8,
    int direction = 1,
  }) {
    if (_disposed) return;
    final sameOwner = identical(owner, _windowOwner);
    _windowOwner = owner;
    if (moving) scrollActivity();
    _settle ??= Timer(const Duration(milliseconds: 150), _onSettled);
    final previous = _visible.keys.toSet();
    final preserved = <String, ImageInfo>{};
    final wanted = visible.map((p) => p.key).toSet();
    for (final id in _visible.keys.toList()) {
      if (!wanted.contains(id) || _visible[id]!.pixels != pixels) {
        final old = _visible.remove(id)!;
        if (wanted.contains(id) && old.detail != null) {
          preserved[id] = old.detail!.clone();
        }
        old.dispose();
        _notify(id);
      }
    }
    for (final photo in visible) {
      _visible.putIfAbsent(
        photo.key,
        () =>
            _VisibleImage(photo, pixels)..detail = preserved.remove(photo.key),
      );
      _recent.remove(photo.key);
      _recent.add(photo.key);
    }
    while (_recent.length > 192) {
      _recent.remove(_recent.first);
    }
    final nextAhead = ahead
        .take(64)
        .where((p) => !wanted.contains(p.key))
        .toList();
    final nextKeys = nextAhead.map((p) => p.key).toSet();
    // Start at two rows only for a new/discontinuous direction. Shrinking an
    // expanded window on every forward row cancels useful queued prefetch and
    // leaves the native lane idle while those first rows await pixel delivery.
    final continuous =
        sameOwner &&
        _prefetchDirection == direction &&
        _aheadWindow.any(
          (p) => wanted.contains(p.key) || nextKeys.contains(p.key),
        );
    _continuousMotion = moving && continuous;
    _prefetchExpanded = _prefetchExpanded && continuous;
    _prefetchDirection = direction;
    _ahead.clear();
    _aheadWindow = nextAhead;
    for (final photo
        in _prefetchExpanded
            ? _aheadWindow
            : _aheadWindow.take(initialPrefetch)) {
      if (!wanted.contains(photo.key)) _ahead[photo.key] = photo;
    }
    _cancelUnneeded();
    _ensureWindow();
    for (final id in wanted.difference(previous)) {
      _notify(id);
    }
  }

  void _onSettled() {
    _settle = null;
    _settled = true;
    _continuousMotion = false;
    _cancelUnneeded();
    _ensureWindow();
  }

  void detachWindow(Object owner) {
    if (!identical(owner, _windowOwner)) return;
    _windowOwner = null;
    _settle?.cancel();
    _settle = null;
    _settled = false;
    final old = _visible.keys.toList();
    for (final item in _visible.values) {
      item.dispose();
    }
    _visible.clear();
    _ahead.clear();
    _aheadWindow = const [];
    _prefetchExpanded = false;
    _continuousMotion = false;
    _prefetchDirection = null;
    _cancelUnneeded();
    _publishReadiness();
    for (final id in old) {
      _notify(id);
    }
  }

  bool _needed(_Load job) =>
      allowed(job.photo, job.key) &&
      (_coverNeeded(job) ||
          (job.key.quality == ThumbnailQuality.preview
              ? _visible.containsKey(job.photo.key) ||
                    _ahead.containsKey(job.photo.key)
              : _settled && _visible[job.photo.key]?.pixels == job.key.pixels));
  ThumbnailWork _work(_Load job) => _coverNeeded(job)
      ? ThumbnailWork.visiblePreview
      : job.key.quality == ThumbnailQuality.detail
      ? ThumbnailWork.visibleDetail
      : _visible.containsKey(job.photo.key)
      ? ThumbnailWork.visiblePreview
      : ThumbnailWork.speculative;

  void _cancelUnneeded() {
    _retry.removeWhere(
      (key) =>
          key.generation != browser.imageGeneration ||
          !_visible.containsKey(key.media.$1) &&
              !_covers.values.any((item) => item.photo.key == key.media.$1),
    );
    for (final job in _queue.toList()) {
      if (!_needed(job)) {
        _queue.remove(job);
        _loads.remove(job.key);
        PaintingBinding.instance.imageCache.evict(job.key);
        job.result.completeError(
          const MediaFailure(MediaFailureKind.cancelled),
        );
      }
    }
    browser.reprioritizeImages();
  }

  bool _needsDetail(_VisibleImage item) {
    final image = item.detail?.image;
    if (image == null) return true;
    final sourceEdge = math.max(item.photo.width, item.photo.height);
    final requiredEdge = sourceEdge > 0
        ? math.min(item.pixels, sourceEdge)
        : item.pixels;
    // A retained clear frame remains sufficient after a denser/smaller grid
    // target. Reading and decoding a smaller replacement adds no detail.
    return math.max(image.width, image.height) < requiredEdge;
  }

  void _ensureWindow() {
    if (_disposed) return;
    for (final item in _covers.values.toList()) {
      final k = key(item.photo, item.pixels, ThumbnailQuality.detail);
      if (item.stream == null &&
          item.error == null &&
          _needsDetail(item) &&
          allowed(item.photo, k)) {
        _resolveDetail(item, k);
      }
    }
    for (final item in _visible.values.toList()) {
      final detailKey = key(item.photo, item.pixels, ThumbnailQuality.detail);
      if (!allowed(item.photo, detailKey)) continue;
      final status = PaintingBinding.instance.imageCache.statusForKey(
        detailKey,
      );
      // Look up existing detail before considering a byte/preview read.
      if (item.error == null &&
          item.stream == null &&
          _needsDetail(item) &&
          (status.keepAlive || status.live || status.pending || _settled)) {
        if (status.keepAlive ||
            status.live ||
            status.pending ||
            _previews.containsKey(
              key(item.photo, 128, ThumbnailQuality.preview),
            )) {
          _resolveDetail(item, detailKey);
        }
      }
      if (item.detail != null) {
        _previewFromDetail(item);
      } else {
        _ensurePreview(item.photo);
      }
    }
    if (_ahead.isNotEmpty &&
        _ahead.values.every(
          (p) => _previews.containsKey(key(p, 128, ThumbnailQuality.preview)),
        )) {
      _prefetchExpanded = true;
      for (final photo in _aheadWindow) {
        _ahead[photo.key] = photo;
      }
    }
    for (final photo in _ahead.values.toList()) {
      _ensurePreview(photo);
    }
    _schedulePump();
    _publishReadiness();
  }

  void _resolveDetail(_VisibleImage item, ThumbnailKey detailKey) {
    final stream = ThumbnailProvider(
      this,
      item.photo,
      detailKey,
    ).resolve(ImageConfiguration.empty);
    item.stream = stream;
    final listener = ImageStreamListener(
      (info, synchronous) {
        if (!allowed(item.photo, detailKey) || !_currentItem(item)) {
          info.dispose();
          return;
        }
        item.detail?.dispose();
        item.detail = info;
        item.error = null;
        if (identical(_visible[item.photo.key], item)) _previewFromDetail(item);
        _notify(item.photo.key);
      },
      onError: (Object error, StackTrace? stack) {
        if (!_currentItem(item)) return;
        item.stream?.removeListener(item.listener!);
        item.stream = null;
        item.listener = null;
        if (error is! MediaFailure ||
            (error.kind != MediaFailureKind.cancelled &&
                error.kind != MediaFailureKind.stale)) {
          item.error = error;
          item.errorQuality = ThumbnailQuality.detail;
        }
        _notify(item.photo.key);
        if (item.error == null && !_disposed) {
          scheduleMicrotask(() {
            PaintingBinding.instance.imageCache.evict(detailKey);
            _ensureWindow();
          });
        }
      },
      reportErrors: false,
    );
    item.listener = listener;
    stream.addListener(listener);
  }

  void _ensurePreview(Photo photo) {
    final k = key(photo, 128, ThumbnailQuality.preview);
    if (!allowed(photo, k) ||
        _previews.containsKey(k) ||
        _loads.containsKey(k)) {
      return;
    }
    if (_visible[photo.key]?.error != null) return;
    _load(photo, k).then(
      (info) {
        info.dispose();
        _notify(photo.key);
        _ensureWindow();
      },
      onError: (Object error, StackTrace stack) {
        final item = _visible[photo.key];
        if (item != null &&
            allowed(photo, k) &&
            (error is! MediaFailure ||
                (error.kind != MediaFailureKind.cancelled &&
                    error.kind != MediaFailureKind.stale))) {
          item.error = error;
          item.errorQuality = ThumbnailQuality.preview;
          _notify(photo.key);
        } else if (!_disposed && allowed(photo, k)) {
          scheduleMicrotask(_ensureWindow);
        }
      },
    );
  }

  // Publish pixels before completing the shared Future/removing its load key.
  // Other completion callbacks may immediately schedule this same window.
  void _retainPreview(_Load job, ImageInfo info) {
    if (allowed(job.photo, job.key) &&
        !_previews.containsKey(job.key) &&
        (_recent.contains(job.photo.key) ||
            _visible.containsKey(job.photo.key) ||
            _ahead.containsKey(job.photo.key)) &&
        _makeRoom(job.photo.key, info.image.width * info.image.height * 4)) {
      final entry = _Preview(info.image.clone());
      _previews[job.key] = entry;
      _previewPixels += entry.bytes;
    }
  }

  bool _makeRoom(String id, int bytes) {
    final speculative = !_recent.contains(id) && !_visible.containsKey(id);
    bool needsRoom() =>
        previewEntries >= 256 ||
        _previewPixels + bytes > 16 * 1024 * 1024 ||
        (speculative && speculativeEntries >= 64);
    while (needsRoom()) {
      final candidates = _previews.entries.where(
        (e) =>
            e.value.references == 0 &&
            !_visible.containsKey(e.key.media.$1) &&
            !_recent.contains(e.key.media.$1),
      );
      final victim = candidates.firstOrNull;
      if (victim == null) {
        capacityLimited = true;
        return false;
      }
      _dropPreview(victim.key);
    }
    return true;
  }

  void _previewFromDetail(_VisibleImage item) {
    final k = key(item.photo, 128, ThumbnailQuality.preview);
    if (_previews.containsKey(k) ||
        item.detail == null ||
        !allowed(item.photo, k)) {
      return;
    }
    final image = item.detail!.image;
    final scale = math.min(1.0, 128 / math.max(image.width, image.height));
    final width = math.max(1, (image.width * scale).round());
    final height = math.max(1, (image.height * scale).round());
    if (!_makeRoom(item.photo.key, width * height * 4)) return;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(scale);
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()..filterQuality = FilterQuality.low,
    );
    final picture = recorder.endRecording();
    final preview = _Preview(picture.toImageSync(width, height));
    picture.dispose();
    _previews[k] = preview;
    _previewPixels += preview.bytes;
  }

  ThumbnailFrame? acquire(Photo photo, int pixels, {Object? coverOwner}) {
    final k = key(photo, pixels, ThumbnailQuality.detail);
    if (!allowed(photo, k)) return null;
    final detail =
        (coverOwner == null ? _visible[photo.key] : _covers[coverOwner])
            ?.detail;
    if (detail != null) {
      return ThumbnailFrame(
        detail.image.clone(),
        ThumbnailQuality.detail,
        () {},
      );
    }
    if (coverOwner != null) return null;
    final preview = _previews[key(photo, 128, ThumbnailQuality.preview)];
    if (preview == null || !_visible.containsKey(photo.key)) return null;
    preview.references++;
    return ThumbnailFrame(preview.image.clone(), ThumbnailQuality.preview, () {
      preview.references--;
      if (!preview.retained && preview.references == 0) {
        _retired.remove(preview);
        _previewPixels -= preview.bytes;
        preview.image.dispose();
      }
    });
  }

  bool failed(Photo photo, {Object? coverOwner}) =>
      (coverOwner == null ? _visible[photo.key] : _covers[coverOwner])?.error !=
      null;

  void retry(Photo photo, {Object? coverOwner}) {
    final item = coverOwner == null ? _visible[photo.key] : _covers[coverOwner];
    if (item == null) return;
    final quality = item.errorQuality ?? ThumbnailQuality.preview;
    item.error = null;
    item.errorQuality = null;
    final k = key(
      photo,
      quality == ThumbnailQuality.preview ? 128 : item.pixels,
      quality,
    );
    _retry.add(k);
    PaintingBinding.instance.imageCache.evict(k);
    if (quality == ThumbnailQuality.preview) {
      _dropPreview(k);
    } else {
      // Retry only the failed quality. A valid preview or previous-size clear
      // frame remains drawable until the replacement actually arrives.
      if (item.stream != null && item.listener != null) {
        item.stream!.removeListener(item.listener!);
      }
      item.stream = null;
      item.listener = null;
    }
    _ensureWindow();
  }

  Future<ImageInfo> _load(Photo photo, ThumbnailKey key) {
    final existing = _loads[key];
    if (existing != null) {
      return existing.result.future.then((info) => info.clone());
    }
    final job = _Load(photo, key, _retry.remove(key));
    _loads[key] = job;
    _queue.add(job);
    _schedulePump();
    return job.result.future.then((info) => info.clone());
  }

  void _schedulePump() {
    if (_pumpScheduled || _disposed) return;
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      _pump();
    });
  }

  void _pump() {
    if (_disposed) return;
    // Four source reads may overlap four codecs, with at most eight jobs
    // (including returned buffers) in flight. A byte-cache hit uses no read
    // quota, so unrelated slow grid I/O cannot block a cached sidebar cover.
    while (_active < 8 && _queue.isNotEmpty) {
      _Load? selected;
      Uint8List? selectedBytes;
      for (final candidate in _queue) {
        final cached = candidate.reload
            ? null
            : browser.cachedThumbnail(
                candidate.photo,
                candidate.key.pixels,
                browser.generation,
              );
        final readEligible =
            _reading < 4 &&
            switch (_work(candidate)) {
              ThumbnailWork.speculative =>
                _speculative < (_mayUseSecondSpeculative ? 2 : 1),
              ThumbnailWork.visibleDetail => _detail < 2,
              _ => true,
            };
        if (cached == null && !readEligible) continue;
        if (selected == null || _rank(candidate) < _rank(selected)) {
          selected = candidate;
          selectedBytes = cached;
        }
      }
      if (selected == null) break;
      final job = selected;
      _queue.remove(job);
      if (!_needed(job)) {
        _loads.remove(job.key);
        job.result.completeError(
          const MediaFailure(MediaFailureKind.cancelled),
        );
        continue;
      }
      if (selectedBytes == null) {
        job.startedWork = _work(job);
        if (job.startedWork == ThumbnailWork.speculative) _speculative++;
        if (job.startedWork == ThumbnailWork.visibleDetail) _detail++;
        _reading++;
        maxReading = math.max(maxReading, _reading);
      }
      _active++;
      maxActive = math.max(maxActive, _active);
      _run(job, selectedBytes);
    }
  }

  int _rank(_Load job) => switch (_work(job)) {
    ThumbnailWork.visiblePreview => 0,
    ThumbnailWork.visibleDetail => 1,
    ThumbnailWork.speculative => 2,
  };

  final _decodeQueue = <(_Load, Uint8List, Completer<ImageInfo>)>[];
  void _drainDecodes() {
    while (_decoding < 4 && _decodeQueue.isNotEmpty) {
      final next = _decodeQueue.reduce(
        (a, b) => _rank(a.$1) <= _rank(b.$1) ? a : b,
      );
      _decodeQueue.remove(next);
      _decoding++;
      maxDecoding = math.max(maxDecoding, _decoding);
      _decode(
        next.$1,
        next.$2,
      ).then(next.$3.complete, onError: next.$3.completeError).whenComplete(() {
        _decoding--;
        _drainDecodes();
      });
    }
  }

  Future<ImageInfo> _decode(_Load job, Uint8List bytes) async {
    if (!allowed(job.photo, job.key)) {
      throw const MediaFailure(MediaFailureKind.stale);
    }
    if (!_needed(job)) throw const MediaFailure(MediaFailureKind.cancelled);
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      if (!_needed(job)) throw const MediaFailure(MediaFailureKind.cancelled);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (!_needed(job)) throw const MediaFailure(MediaFailureKind.cancelled);
      final scale = math.min(
        1.0,
        job.key.pixels / math.max(descriptor.width, descriptor.height),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      final frame = await codec.getNextFrame();
      decodeCount++;
      if (!allowed(job.photo, job.key)) {
        frame.image.dispose();
        throw const MediaFailure(MediaFailureKind.stale);
      }
      return ImageInfo(image: frame.image);
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<Uint8List> _read(_Load job) async {
    try {
      return await browser.thumbnail(
        job.photo,
        job.key.pixels,
        browser.generation,
        // A running read remains useful if the same identity returns. The
        // browser separately keeps actual native occupancy until completion.
        isNeeded: () => _needed(job),
        work: () => _work(job),
        // Native admission rechecks this after any queue wait. An earlier
        // viewport permission cannot authorize a second read after reversal.
        allowExtraSpeculative: () => _mayUseSecondSpeculative,
        reload: job.reload,
      );
    } finally {
      // These are READ quotas. The browser Future completes only after the
      // real source finishes (or queued work is cancelled before starting).
      // Pixel decoding has its own bounded stage; it cannot keep a native
      // quota occupied after the corresponding source Future completes.
      _reading--;
      if (job.startedWork == ThumbnailWork.speculative) _speculative--;
      if (job.startedWork == ThumbnailWork.visibleDetail) _detail--;
      _schedulePump();
    }
  }

  Future<void> _run(_Load job, Uint8List? cachedBytes) async {
    try {
      final bytes = cachedBytes ?? await _read(job);
      if (!allowed(job.photo, job.key)) {
        throw const MediaFailure(MediaFailureKind.stale);
      }
      // Returned bytes and codecs stay within the eight in-flight jobs.
      // Visible previews/covers overtake unstarted speculative decodes.
      final decoded = Completer<ImageInfo>();
      _decodeQueue.add((job, bytes, decoded));
      _drainDecodes();
      final info = await decoded.future;
      if (job.key.quality == ThumbnailQuality.preview) {
        _retainPreview(job, info);
      }
      job.result.complete(info);
      scheduleMicrotask(info.dispose);
    } catch (error, stack) {
      job.result.completeError(error, stack);
      // Failed/cancelled completers cannot remain a cache hit on the next visit.
      scheduleMicrotask(
        () => PaintingBinding.instance.imageCache.evict(job.key),
      );
    } finally {
      _loads.remove(job.key);
      _active--;
      _schedulePump();
    }
  }

  void _dropPreview(ThumbnailKey key) {
    final entry = _previews.remove(key);
    if (entry == null) return;
    entry.retained = false;
    if (entry.references == 0) {
      _previewPixels -= entry.bytes;
      entry.image.dispose();
    } else {
      _retired.add(entry);
    }
  }

  void _browserChanged() {
    if (_disposed) return;
    if (_generation != browser.imageGeneration) {
      _generation = browser.imageGeneration;
      for (final k in _previews.keys.toList()) {
        _dropPreview(k);
      }
      _recent.clear();
      final ids = _visible.keys.toList();
      for (final item in _visible.values) {
        item.dispose();
      }
      _visible.clear();
      for (final item in _covers.values) {
        item.dispose();
        item.stream = null;
        item.listener = null;
        item.error = null;
        item.errorQuality = null;
        _notify(item.photo.key);
      }
      _ahead.clear();
      _aheadWindow = const [];
      _prefetchExpanded = false;
      _continuousMotion = false;
      _prefetchDirection = null;
      for (final id in ids) {
        _notify(id);
      }
      _cancelUnneeded();
    }
    for (final id in {
      ..._visible.keys,
      ..._covers.values.map((item) => item.photo.key),
    }) {
      _notify(id);
    }
    _ensureWindow();
  }

  @override
  void didHaveMemoryPressure() {
    _ahead.clear();
    _aheadWindow = const [];
    _prefetchExpanded = false;
    _continuousMotion = false;
    _prefetchDirection = null;
    for (final k in _previews.keys.toList()) {
      if (!_visible.containsKey(k.media.$1)) _dropPreview(k);
    }
    _recent.removeWhere((id) => !_visible.containsKey(id));
    _cancelUnneeded();
  }

  void dispose() {
    if (_disposed) return;
    detachWindow(_windowOwner ?? this);
    _disposed = true;
    for (final item in _covers.values) {
      item.dispose();
    }
    _covers.clear();
    browser.removeListener(_browserChanged);
    WidgetsBinding.instance.removeObserver(this);
    _cancelUnneeded();
    for (final k in _previews.keys.toList()) {
      _dropPreview(k);
    }
    _recent.clear();
    _listeners.clear();
    _visibleReady.dispose();
  }
}

class ThumbnailScope extends InheritedWidget {
  const ThumbnailScope({super.key, required this.images, required super.child});
  final ThumbnailImages images;
  static ThumbnailImages? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThumbnailScope>()?.images;
  @override
  bool updateShouldNotify(ThumbnailScope oldWidget) =>
      images != oldWidget.images;
}

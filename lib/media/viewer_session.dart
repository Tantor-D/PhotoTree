import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'browser.dart';
import 'media_source.dart';

// Fixed entry order, current identity and bounded decoded images belong here.
class ViewerSession extends ChangeNotifier {
  ViewerSession(this.browser, List<Photo> photos, String key)
    : order = List.unmodifiable(photos.map((p) => p.key)),
      currentKey = key {
    browser.addListener(_changed);
    _changed();
  }
  final PhotoBrowser browser;
  final List<String> order;
  String currentKey;
  final _images = <String, ui.Image>{};
  final _sizes = <String, int>{};
  final _jobs = <String, int>{};
  final errors = <String, MediaFailureKind>{};
  int _epoch = 0, _generation = -1;
  bool _disposed = false, invalid = false;
  static const budget = 96 * 1024 * 1024;
  int peakBytes = 0;
  int get heldBytes => _images.values.fold(
    0,
    (sum, image) => sum + image.width * image.height * 4,
  );
  bool get verified => browser.phase == BrowsePhase.ready && !invalid;
  Photo? get current => _photo(currentKey);
  Photo? _photo(String key) {
    for (final p in browser.photos) {
      if (p.key == key) return p;
    }
    return null;
  }

  ui.Image? image(String key) => verified ? _images[key] : null;
  String? neighbor(int direction) {
    for (
      var i = order.indexOf(currentKey) + direction;
      i >= 0 && i < order.length;
      i += direction
    ) {
      if (_photo(order[i]) != null) return order[i];
    }
    return null;
  }

  void _changed() {
    if (_disposed) return;
    if (_generation != browser.generation) {
      _generation = browser.generation;
      _epoch++;
      _jobs.clear();
      _clear();
      errors.clear();
    }
    if (browser.phase == BrowsePhase.ready ||
        browser.phase == BrowsePhase.denied ||
        browser.phase == BrowsePhase.failed) {
      invalid = current == null;
    }
    notifyListeners();
    if (verified) _loadWindow();
  }

  void turn(int direction) {
    final next = neighbor(direction);
    if (!verified || next == null) return;
    currentKey = next;
    _epoch++;
    _jobs.clear();
    _retainWindow();
    notifyListeners();
    _loadWindow();
  }

  void settleOperation() {
    if (browser.phase != BrowsePhase.ready || _disposed) return;
    if (current == null) {
      final next = neighbor(1) ?? neighbor(-1);
      if (next != null) currentKey = next;
    }
    _changed();
  }

  Set<String> get _window => {currentKey, ?neighbor(-1), ?neighbor(1)};
  void _drop(String key) {
    _images.remove(key)?.dispose();
    _sizes.remove(key);
  }

  void _clear() {
    for (final key in _images.keys.toList()) {
      _drop(key);
    }
  }

  void _retainWindow() {
    for (final key in _images.keys.toList()) {
      if (!_window.contains(key) ||
          (key != currentKey && (_sizes[key] ?? 0) > 1024)) {
        _drop(key);
      }
    }
  }

  void _loadWindow() {
    unawaited(_loadCurrent());
  }

  Future<void> _loadCurrent() async {
    final key = currentKey;
    if (!_images.containsKey(key)) await _load(key, 512);
    if (_disposed || currentKey != key || !verified) return;
    await _load(key, 2048);
    if (_disposed || currentKey != key || !verified) return;
    for (final direction in [-1, 1]) {
      final key = neighbor(direction);
      if (key != null) unawaited(_load(key, 1024));
    }
  }

  void sharpen() {
    if (verified) unawaited(_load(currentKey, 4096));
  }

  void retry() {
    errors.remove(currentKey);
    unawaited(_load(currentKey, 2048, retry: true));
  }

  Future<void> _load(String key, int pixels, {bool retry = false}) async {
    final photo = _photo(key);
    if (photo == null) return;
    if (photo.kind == MediaKind.video) pixels = math.min(512, pixels);
    if (!verified ||
        _disposed ||
        (_sizes[key] ?? 0) >= pixels ||
        _jobs.containsKey(key) ||
        (!retry && errors.containsKey(key))) {
      return;
    }
    final epoch = _epoch, ticket = browser.generation;
    _jobs[key] = pixels;
    bool needed() =>
        !_disposed &&
        epoch == _epoch &&
        browser.current(ticket) &&
        _window.contains(key);
    ui.Codec? codec;
    ui.Image? decoded;
    try {
      final bytes = photo.kind == MediaKind.video
          ? await browser.thumbnail(photo, pixels, ticket, isNeeded: needed)
          : await browser.display(
              photo,
              pixels,
              ticket,
              isNeeded: needed,
              priority: key == currentKey,
            );
      if (!needed()) return;
      // The adapter supplies bounded, oriented PNG; this additional limit also
      // protects the boundary if an adapter returns an oversized image.
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final ratio = math.min(
          1.0,
          pixels / math.max(descriptor.width, descriptor.height),
        );
        final width = math.max(1, (descriptor.width * ratio).floor());
        final height = math.max(1, (descriptor.height * ratio).floor());
        final incoming = width * height * 4;
        for (final other in _images.keys.toList()) {
          if (heldBytes + incoming <= budget) break;
          if (other != currentKey) _drop(other);
        }
        if (heldBytes + incoming > budget) _drop(key);
        if (heldBytes + incoming > budget) {
          throw const MediaFailure(MediaFailureKind.unavailable);
        }
        codec = await descriptor.instantiateCodec(
          targetWidth: width,
          targetHeight: height,
        );
        decoded = (await codec.getNextFrame()).image;
      } finally {
        descriptor.dispose();
        buffer.dispose();
      }
      if (!needed()) return;
      // Other decoders may have completed while this one was awaiting a frame.
      for (final other in _images.keys.toList()) {
        if (heldBytes + decoded.width * decoded.height * 4 <= budget) break;
        if (other != currentKey) _drop(other);
      }
      if (heldBytes + decoded.width * decoded.height * 4 > budget) _drop(key);
      if (heldBytes + decoded.width * decoded.height * 4 > budget) return;
      peakBytes = math.max(
        peakBytes,
        heldBytes + decoded.width * decoded.height * 4,
      );
      _drop(key);
      _images[key] = decoded;
      decoded = null;
      _sizes[key] = pixels;
      errors.remove(key);
      notifyListeners();
    } catch (error) {
      if (needed()) {
        errors[key] = error is MediaFailure
            ? error.kind
            : MediaFailureKind.unavailable;
        notifyListeners();
      }
    } finally {
      decoded?.dispose();
      codec?.dispose();
      if (epoch == _epoch) _jobs.remove(key);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    browser.removeListener(_changed);
    _clear();
    super.dispose();
  }
}

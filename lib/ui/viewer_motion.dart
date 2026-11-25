import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';

enum ViewerGesture { pending, pan, page, dismiss, pinch }

// Geometry and input only. No photo identities, navigation, storage or plugins.
class ViewerMotion extends ChangeNotifier {
  ViewerMotion({required TickerProvider vsync, bool reduceAnimations = false})
    // Keep a public input name while updates go through the preference setter.
    // ignore: prefer_initializing_formals
    : _reduceAnimations = reduceAnimations {
    _driver = AnimationController(
      vsync: vsync,
      duration: const Duration(milliseconds: 300),
    );
    _driver.addListener(() {
      final t = Curves.easeOutCubic.transform(_driver.value);
      rect = Rect.lerp(_from, _to, t)!;
      background = _fromBackground + (_toBackground - _fromBackground) * t;
      page = _fromPage + (_toPage - _fromPage) * t;
      imageOpacity = _fromOpacity + (_toOpacity - _fromOpacity) * t;
      notifyListeners();
    });
    _driver.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        final done = _done;
        _done = null;
        done?.call();
      }
    });
  }
  late final AnimationController _driver;
  bool _reduceAnimations;
  bool allowZoom = true;
  bool get reduceAnimations => _reduceAnimations;

  /// An explicit presentation preference, supplied by the UI adapter. Direct
  /// pointer movement and gesture thresholds are identical in both modes.
  set reduceAnimations(bool value) {
    if (_reduceAnimations == value) return;
    _reduceAnimations = value;
    if (value && animating) _finishWithoutAnimation();
  }

  Size viewport = Size.zero;
  Rect base = Rect.zero, rect = Rect.zero;
  double background = 1, page = 0, imageOpacity = 1;
  double get scale => base.width == 0 ? 1 : rect.width / base.width;
  bool get animating => _driver.isAnimating;
  ViewerGesture gesture = ViewerGesture.pending;
  VoidCallback? onTap, onDismiss;
  ValueChanged<int>? onPage;
  bool canPrevious = false, canNext = false;
  Rect _from = Rect.zero, _to = Rect.zero;
  double _fromBackground = 1, _toBackground = 1, _fromPage = 0, _toPage = 0;
  double _fromOpacity = 1, _toOpacity = 1;
  VoidCallback? _done;
  final _pointers = <int, Offset>{};
  Rect _startRect = Rect.zero;
  Offset _startPoint = Offset.zero;
  double _startPage = 0, _startBackground = 1, _distance = 1;
  VelocityTracker? _velocity;
  Duration? _lastTap;
  Offset _tapPosition = Offset.zero;
  bool _moved = false;

  Rect fitted(Size image) {
    final factor = math.min(
      viewport.width / image.width,
      viewport.height / image.height,
    );
    return Rect.fromCenter(
      center: viewport.center(Offset.zero),
      width: image.width * factor,
      height: image.height * factor,
    );
  }

  void layout(Size size, Size image, {Rect? origin, bool startOpening = true}) {
    final oldBase = base;
    final zoom = scale.clamp(1.0, 4.0);
    final focus = oldBase.isEmpty
        ? const Offset(.5, .5)
        : Offset(
            (viewport.width / 2 - rect.left) / rect.width,
            (viewport.height / 2 - rect.top) / rect.height,
          );
    stop();
    viewport = size;
    base = fitted(image);
    rect = _bounded(
      Rect.fromLTWH(
        size.width / 2 - focus.dx * base.width * zoom,
        size.height / 2 - focus.dy * base.height * zoom,
        base.width * zoom,
        base.height * zoom,
      ),
    );
    page = 0;
    background = 1;
    imageOpacity = 1;
    if (origin != null) {
      rect = origin;
      background = 0;
      if (startOpening) {
        animate(base, duration: const Duration(milliseconds: 260));
      }
    }
  }

  void stop() {
    _done = null;
    _driver.stop();
  }

  void suspend() {
    stop();
    _pointers.clear();
  }

  void animate(
    Rect target, {
    double backdrop = 1,
    double offset = 0,
    double opacity = 1,
    VoidCallback? done,
    Duration duration = const Duration(milliseconds: 300),
  }) {
    stop();
    _fromOpacity = imageOpacity;
    _toOpacity = opacity;
    _from = rect;
    _to = target;
    _fromBackground = background;
    _toBackground = backdrop;
    _fromPage = page;
    _toPage = offset;
    _done = done;
    if (_reduceAnimations) {
      _finishWithoutAnimation();
      return;
    }
    _driver.duration = duration;
    _driver.forward(from: 0);
  }

  void _finishWithoutAnimation() {
    _driver.stop();
    final done = _done;
    _done = null;
    rect = _to;
    background = _toBackground;
    page = _toPage;
    imageOpacity = _toOpacity;
    notifyListeners();
    done?.call();
  }

  void close(Rect? target, VoidCallback done) => animate(
    target ?? rect,
    backdrop: 0,
    opacity: target == null ? 0 : 1,
    done: done,
  );
  void resetPhoto(Size image) {
    stop();
    base = fitted(image);
    rect = base;
    page = 0;
    background = 1;
    imageOpacity = 1;
    notifyListeners();
  }

  Rect _bounded(Rect value) {
    final x = value.width <= viewport.width
        ? (viewport.width - value.width) / 2
        : value.left.clamp(viewport.width - value.width, 0.0);
    final y = value.height <= viewport.height
        ? (viewport.height - value.height) / 2
        : value.top.clamp(viewport.height - value.height, 0.0);
    return Rect.fromLTWH(x, y, value.width, value.height);
  }

  Offset get _center =>
      _pointers.values.reduce((a, b) => a + b) / _pointers.length.toDouble();
  double get _span => _pointers.length < 2
      ? 1
      : (_pointers.values.first - _pointers.values.elementAt(1)).distance.clamp(
          1.0,
          double.infinity,
        );
  void _capture() {
    _startRect = rect;
    _startPoint = _center;
    _distance = _span;
    _startPage = page;
    _startBackground = background;
  }

  void down(PointerDownEvent event) {
    stop();
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 1) {
      gesture = scale > 1.01 ? ViewerGesture.pan : ViewerGesture.pending;
      _moved = false;
      _velocity = VelocityTracker.withKind(event.kind)
        ..addPosition(event.timeStamp, event.localPosition);
    } else {
      gesture = ViewerGesture.pinch;
      _moved = true;
    }
    _capture();
  }

  void move(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    _velocity?.addPosition(event.timeStamp, event.localPosition);
    final delta = _center - _startPoint;
    if (delta.distance > 12) _moved = true;
    if (_pointers.length > 1) {
      if (!allowZoom) return;
      gesture = ViewerGesture.pinch;
      final ratio =
          (_span / _distance * _startRect.width / base.width).clamp(.8, 4.4) *
          base.width /
          _startRect.width;
      final point = _center - (_startPoint - _startRect.topLeft) * ratio;
      rect = Rect.fromLTWH(
        point.dx,
        point.dy,
        _startRect.width * ratio,
        _startRect.height * ratio,
      );
    } else if (gesture == ViewerGesture.pinch || gesture == ViewerGesture.pan) {
      // A gesture which began zoomed never changes into paging/dismissal.
      rect = _bounded(_startRect.shift(delta));
    } else {
      if (gesture == ViewerGesture.pending && delta.distance > 12) {
        if (delta.dx.abs() > delta.dy.abs() * 1.2) gesture = ViewerGesture.page;
        if (delta.dy > delta.dx.abs() * 1.2) gesture = ViewerGesture.dismiss;
      }
      if (gesture == ViewerGesture.page) {
        final desired = _startPage + delta.dx;
        page = (desired > 0 ? canPrevious : canNext) ? desired : desired * .22;
      } else if (gesture == ViewerGesture.dismiss) {
        final dy = math.max(0.0, delta.dy);
        final shrink = (1 - dy / viewport.height * .4).clamp(.6, 1.0);
        rect = Rect.fromCenter(
          center: _startRect.center + delta,
          width: _startRect.width * shrink,
          height: _startRect.height * shrink,
        );
        background = (_startBackground - dy / viewport.height).clamp(0.0, 1.0);
      }
    }
    notifyListeners();
  }

  void up(PointerUpEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers.remove(event.pointer);
    if (_pointers.isNotEmpty) {
      _capture();
      return;
    }
    final velocity = _velocity?.getVelocity().pixelsPerSecond ?? Offset.zero;
    if (!_moved && gesture != ViewerGesture.pinch) {
      if (allowZoom &&
          _lastTap != null &&
          event.timeStamp - _lastTap! < const Duration(milliseconds: 300) &&
          (event.localPosition - _tapPosition).distance < 32) {
        _lastTap = null;
        final zoom = scale > 1.01 ? 1.0 : 2.5;
        final factor = zoom / scale;
        final top =
            event.localPosition - (event.localPosition - rect.topLeft) * factor;
        animate(
          _bounded(
            Rect.fromLTWH(
              top.dx,
              top.dy,
              base.width * zoom,
              base.height * zoom,
            ),
          ),
        );
      } else {
        _lastTap = event.timeStamp;
        _tapPosition = event.localPosition;
        onTap?.call();
        if (scale < 1 || background < 1) animate(base);
      }
      return;
    }
    _lastTap = null;
    if (gesture == ViewerGesture.page) {
      final direction = page < 0 ? 1 : -1;
      final allowed = direction == 1 ? canNext : canPrevious;
      final commit =
          page.abs() > viewport.width * .25 ||
          (page.abs() > 24 &&
              velocity.dx.abs() > 700 &&
              page * velocity.dx > 0);
      animate(
        base,
        offset: allowed && commit ? -direction * viewport.width : 0,
        done: allowed && commit ? () => onPage?.call(direction) : null,
      );
    } else if (gesture == ViewerGesture.dismiss) {
      final dy = rect.center.dy - _startRect.center.dy;
      if (dy > viewport.height * .25 || (dy > 48 && velocity.dy > 900)) {
        onDismiss?.call();
      } else {
        animate(base);
      }
    } else {
      final zoom = scale.clamp(1.0, 4.0);
      animate(
        _bounded(
          Rect.fromCenter(
            center: rect.center,
            width: base.width * zoom,
            height: base.height * zoom,
          ),
        ),
      );
    }
  }

  void cancel(PointerCancelEvent event) {
    _pointers.clear();
    final zoom = scale.clamp(1.0, 4.0);
    animate(
      _bounded(
        Rect.fromCenter(
          center: rect.center,
          width: base.width * zoom,
          height: base.height * zoom,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _driver.dispose();
    super.dispose();
  }
}

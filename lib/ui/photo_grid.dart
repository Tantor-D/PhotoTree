import 'interface_strings.dart';
import '../library/physical_operations.dart';
import 'media_operation_dialog.dart';

import 'dart:async';
import 'dart:math' as math;

import '../library/favorites.dart';
import '../library/views.dart';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../media/browser.dart';
import '../media/media_source.dart';
import 'photo_viewer.dart';
import 'thumbnail_images.dart';
import 'video_playback.dart';
import 'visual_style.dart';
import '../dev/acceptance_trace.dart';

enum GridDensity { comfortable, compact, dense }

class GridPosition {
  String? anchor;
  double relative = 0;
  List<String> order = [];
}

class PhotoGrid extends StatefulWidget {
  const PhotoGrid({
    super.key,
    required this.browser,
    this.albumKey,
    this.position,
    this.favorites,
    this.physical,
    this.view = LibraryView.all,
    this.density = GridDensity.compact,
    this.onDensityChanged,
    this.scopeTitle,
    this.navigationButton,
    this.menuButton,
    this.glassEnabled = true,
    this.emptyContent,
  });
  final PhotoBrowser browser;
  final Favorites? favorites;
  final PhysicalOperations? physical;
  final LibraryView view;
  final String? albumKey;
  final GridPosition? position;
  final GridDensity density;
  final ValueChanged<GridDensity>? onDensityChanged;
  final String? scopeTitle;
  final Widget? navigationButton, menuButton;
  final bool glassEnabled;
  final Widget? emptyContent;
  @override
  State<PhotoGrid> createState() => _PhotoGridState();
}

class _PhotoGridState extends State<PhotoGrid>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _gap = 2.0;
  static const _minimumTile = 48.0;
  late final _scroll = ScrollController(
    keepScrollOffset: false,
    onAttach: (position) =>
        position.isScrollingNotifier.addListener(_imageScrollState),
    onDetach: (position) =>
        position.isScrollingNotifier.removeListener(_imageScrollState),
  );
  ThumbnailImages? _images;
  bool _ownsImages = false;
  double _viewportHeight = 0, _cell = 0, _lastOffset = 0;
  int _direction = 1;
  List<String> _imageWindow = [];
  final _glassChanges = ValueNotifier<int>(0);
  bool _gridBlurSuspended = false, _blurSettled = false;
  Timer? _blurSettle, _blurDeadline;
  int _blurEpoch = 0;
  int? _blurGeneration;

  void _setGridBlurSuspended(bool value) {
    if (_gridBlurSuspended == value) return;
    _gridBlurSuspended = value;
    void notify() {
      if (mounted) _glassChanges.value++;
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => notify());
    } else {
      notify();
    }
  }

  bool get _scrolling =>
      _scroll.positions.length == 1 &&
      _scroll.position.isScrollingNotifier.value;

  void _suspendGridBlur() {
    _blurEpoch++;
    _blurSettle?.cancel();
    _blurDeadline?.cancel();
    _blurSettle = _blurDeadline = null;
    _blurSettled = false;
    _blurGeneration = widget.browser.imageGeneration;
    _setGridBlurSuspended(true);
  }

  void _cancelGridBlur() {
    _blurEpoch++;
    _blurSettle?.cancel();
    _blurDeadline?.cancel();
    _blurSettle = _blurDeadline = null;
    _blurSettled = false;
    _setGridBlurSuspended(false);
  }

  void _scheduleBlurRestoration() {
    if (!_gridBlurSuspended || _blurDeadline != null) return;
    _blurSettle = Timer(const Duration(milliseconds: 150), () {
      _blurSettled = true;
      _restoreReadyBlur();
    });
    // Only a new actual offset/activity starts another interval. Builds,
    // retries and late pixels cannot postpone this bound.
    _blurDeadline = Timer(const Duration(milliseconds: 1000), _cancelGridBlur);
  }

  void _restoreReadyBlur() {
    if (!_gridBlurSuspended ||
        !_blurSettled ||
        _scrolling ||
        _images?.visibleDetailsReady.value != true) {
      return;
    }
    final epoch = _blurEpoch;
    // Let tiles consume the final delivered pixels before restoring the filter.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          epoch == _blurEpoch &&
          !_scrolling &&
          _images?.visibleDetailsReady.value == true) {
        _cancelGridBlur();
      }
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _blurAccessChanged() {
    if (!widget.browser.foreground ||
        widget.browser.phase != BrowsePhase.ready ||
        _blurGeneration != widget.browser.imageGeneration) {
      _cancelGridBlur();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _cancelGridBlur();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindImages();
  }

  void _bindImages() {
    final inherited = ThumbnailScope.maybeOf(context);
    final next =
        inherited ??
        (_ownsImages && identical(_images?.browser, widget.browser)
            ? _images!
            : ThumbnailImages(widget.browser));
    if (identical(next, _images)) return;
    _cancelGridBlur();
    _images?.visibleDetailsReady.removeListener(_restoreReadyBlur);
    _images?.detachWindow(this);
    if (_ownsImages) _images?.dispose();
    _images = next;
    _ownsImages = inherited == null;
    _images!.visibleDetailsReady.addListener(_restoreReadyBlur);
    _imageWindow = [];
  }

  void _imageScrollState() {
    if (_scrolling) {
      _suspendGridBlur();
    } else {
      _images?.scrollStopped();
      _scheduleBlurRestoration();
    }
  }

  void _imageScroll() {
    if (_scroll.positions.length != 1 || !_scroll.position.hasPixels) return;
    final offset = _scroll.offset;
    if (offset != _lastOffset) {
      _direction = offset > _lastOffset ? 1 : -1;
      _suspendGridBlur();
    }
    _lastOffset = offset;
    _updateImageWindow(moving: true);
    // Programmatic position restoration also notifies the offset listener, but
    // must not grant the continuous-motion second lane.
    _imageScrollState();
  }

  void _updateImageWindow({bool moving = false}) {
    if (_images == null ||
        _rows.isEmpty ||
        _viewportHeight <= 0 ||
        _cell <= 0) {
      return;
    }
    final offset = _scroll.positions.length == 1 && _scroll.position.hasPixels
        ? _scroll.offset
        : 0.0;
    final start = offset + _gridTopInset;
    final end = offset + _viewportHeight - _gridBottomInset;
    // Binary search the first intersecting row; never scan the whole library
    // on a scroll tick. Date headings do not enter media recency.
    var low = 0, high = _rows.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_rows[mid].offset + _rows[mid].extent <= start) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final visible = <Photo>[];
    var last = low;
    for (; last < _rows.length && _rows[last].offset < end; last++) {
      visible.addAll(_rows[last].photos);
    }
    // Start with two rows, then warm up to one screen in the current direction.
    final ahead = <Photo>[];
    var rows = 0;
    final maxRows = math.max(2, ((end - start) / (_cell + _gap)).ceil());
    for (
      var i = _direction > 0 ? last : low - 1;
      i >= 0 && i < _rows.length && rows < maxRows;
      i += _direction
    ) {
      if (_rows[i].photos.isEmpty) continue;
      ahead.addAll(_rows[i].photos);
      rows++;
    }
    final pixels = (_cell * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 512);
    final signature = [
      '${widget.browser.imageGeneration}',
      '$pixels',
      '$_direction',
      ...visible.map((p) => p.key),
      '|',
      ...ahead.map((p) => p.key),
    ];
    if (listEquals(signature, _imageWindow)) {
      if (moving) _images!.scrollActivity();
      return;
    }
    _imageWindow = signature;
    _images!.updateWindow(
      this,
      visible,
      ahead,
      pixels,
      moving: moving,
      initialPrefetch: _lastColumns * 2,
      direction: _direction,
    );
  }

  List<_Row> _rows = [];
  List<String> _oldOrder = [];
  String? _anchor;
  double _relative = 0;
  bool _restoring = false;
  int _layoutRevision = 0;
  List<Photo>? _lastPhotos;
  double _lastWidth = 0;
  String _lastZone = '';
  int _lastColumns = 0;
  TextScaler? _lastTextScaler;
  TextStyle? _lastDateStyle;
  double _gridTopInset = 0, _gridBottomInset = 0;
  final _gridGestureKey = GlobalKey();
  final _pointers = <int, Offset>{};
  bool _multiTouch = false, _blockedSequence = false, _pinchCancelled = false;
  bool _densityRequestPending = false;
  bool _pinchEvaluationScheduled = false;
  double _pinchDistance = 0, _pinchFocalOffset = 0;
  double? _pendingPinchCenter;
  String? _pinchAnchor;
  int? _pinchGeneration;
  final _tileKeys = <String, GlobalKey>{};
  final _selectedPhotos = <String>{};
  bool _selecting = false;
  final _selectionChanged = ValueNotifier<int>(0);
  final _selectionIdentities = <String, String?>{};
  String? _selectionWarning;
  List<Photo> _sweepPhotos = const [];
  final _sweepIndices = <String, int>{};
  final _sweepBaseline = <String>{};
  int _sweepAnchor = 0, _sweepEnd = 0;
  Offset? _sweepPoint;
  bool _sweepAdd = true;
  int? _sweepGeneration;
  late final Ticker _sweepTicker;
  Duration _sweepElapsed = Duration.zero;

  int? _selectionGeneration;
  bool _viewerOpen = false;
  Timer? _minute;
  List<String> _viewerOrder = [];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.browser.addListener(_blurAccessChanged);
    _anchor = widget.position?.anchor;
    _relative = widget.position?.relative ?? 0;
    _oldOrder = widget.position?.order ?? [];
    _scroll.addListener(_capture);
    _scroll.addListener(_imageScroll);
    _sweepTicker = createTicker((elapsed) {
      final seconds = ((elapsed - _sweepElapsed).inMicroseconds / 1000000)
          .clamp(0.0, .05);
      _sweepElapsed = elapsed;
      _sweepScroll(seconds);
    });
    if (widget.view == LibraryView.recent) {
      _minute = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _capture() {
    if (_restoring || !_scroll.hasClients || _rows.isEmpty) return;
    for (final row in _rows) {
      if (row.photos.isNotEmpty &&
          row.offset + row.extent - _gap > _scroll.offset + _gridTopInset) {
        _anchor = row.photos.first.key;
        _relative = row.offset - _scroll.offset;
        _save();
        return;
      }
    }
  }

  @override
  void didUpdateWidget(covariant PhotoGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.browser, widget.browser)) {
      oldWidget.browser.removeListener(_blurAccessChanged);
      widget.browser.addListener(_blurAccessChanged);
      _bindImages();
    }
    if (oldWidget.albumKey != widget.albumKey ||
        oldWidget.view != widget.view) {
      _cancelGridBlur();
    }
    if (oldWidget.density != widget.density) _densityRequestPending = false;
  }

  void _pointerDown(PointerDownEvent event) {
    if (!mounted || _viewerOpen || widget.browser.phase != BrowsePhase.ready) {
      return;
    }
    if (_pointers.isEmpty) {
      _blockedSequence = false;
      _pinchCancelled = false;
    }
    _pointers[event.pointer] = event.position;
    if (_pointers.length != 2 || _multiTouch) {
      if (_pointers.length > 2) _pinchCancelled = true;
      return;
    }
    // A scale recognizer cannot take an arena already won by a scrolling
    // finger. Hold disposes that active drag immediately; removing user-scroll
    // recognition keeps the remaining finger inert until the whole sequence ends.
    _stopSweep();
    _blockedSequence = true;
    _multiTouch = true;
    _pinchGeneration = widget.browser.generation;
    if (_scroll.hasClients) _scroll.position.hold(() {});
    final points = _pointers.values.toList();
    final middle = (points[0] + points[1]) / 2;
    _pinchDistance = (points[0] - points[1]).distance;
    _pinchAnchor = null;
    final viewport = _gridGestureKey.currentContext?.findRenderObject();
    if (viewport is RenderBox) {
      final origin = viewport.localToGlobal(Offset.zero);
      final visible = Rect.fromLTWH(
        origin.dx,
        origin.dy + _gridTopInset,
        viewport.size.width,
        math.max(0, viewport.size.height - _gridTopInset - _gridBottomInset),
      );
      var nearest = double.infinity;
      for (final entry in _tileKeys.entries) {
        final tile = entry.value.currentContext?.findRenderObject();
        if (tile is! RenderBox || !tile.attached) continue;
        final rect = tile.localToGlobal(Offset.zero) & tile.size;
        if (!rect.overlaps(visible)) continue;
        final distance = (rect.center - middle).distanceSquared;
        if (distance < nearest) {
          nearest = distance;
          _pinchAnchor = entry.key;
          _pinchFocalOffset = rect.center.dy - middle.dy;
        }
      }
    }
    setState(() {});
  }

  void _pointerMove(PointerMoveEvent event) {
    if (!mounted || !_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.position;
    if (_sweepPoint != null && !_multiTouch) _sweepTo(event.position);
    if (!_multiTouch || _pinchEvaluationScheduled) return;
    _pinchEvaluationScheduled = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _pinchEvaluationScheduled = false;
      if (mounted) _updatePinch();
    });
  }

  void _updatePinch() {
    if (!_multiTouch ||
        _pinchCancelled ||
        _pointers.length != 2 ||
        widget.onDensityChanged == null) {
      return;
    }
    if (widget.browser.phase != BrowsePhase.ready ||
        widget.browser.generation != _pinchGeneration) {
      _pinchCancelled = true;
      return;
    }
    if (_densityRequestPending || _pinchDistance <= 0) return;
    final points = _pointers.values.toList();
    final distance = (points[0] - points[1]).distance;
    final ratio = distance / _pinchDistance;
    final delta = ratio >= 1.18 ? -1 : (ratio <= 1 / 1.18 ? 1 : 0);
    if (delta == 0) return;
    final index = (widget.density.index + delta).clamp(
      0,
      GridDensity.values.length - 1,
    );
    // Discard excess span at either endpoint, so reversing only needs the
    // same threshold instead of retracing an arbitrarily long blocked span.
    _pinchDistance = distance;
    if (index == widget.density.index) return;
    final viewport = _gridGestureKey.currentContext?.findRenderObject();
    if (_pinchAnchor != null && viewport is RenderBox) {
      _anchor = _pinchAnchor;
      _pendingPinchCenter =
          (points[0].dy + points[1].dy) / 2 +
          _pinchFocalOffset -
          viewport.localToGlobal(Offset.zero).dy;
    }
    _densityRequestPending = true;
    widget.onDensityChanged?.call(GridDensity.values[index]);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _densityRequestPending = false;
    });
  }

  void _pointerEnd(PointerEvent event) {
    _stopSweep();
    if (!mounted) return;
    if (event is PointerUpEvent && _pointers.containsKey(event.pointer)) {
      // Moves are coalesced until the next frame. Normal release must consume
      // the final paired positions before removing either pointer; a cancelled
      // sequence deliberately discards that pending sample instead.
      _pointers[event.pointer] = event.position;
      _updatePinch();
    }
    _pointers.remove(event.pointer);
    if (!_multiTouch) return;
    _pinchCancelled = true;
    if (_pointers.isNotEmpty) return;
    if (_scroll.hasClients) {
      _scroll.jumpTo(_scroll.offset.clamp(0.0, _maxScrollOffset));
    }
    setState(() => _multiTouch = false);
    // Keep tap/long-press suppressed through this final pointer-up's arena
    // callbacks, including recognizers which have already accepted a tap.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pointers.isEmpty) _blockedSequence = false;
    });
  }

  // Lazy ListView's estimate can lag behind a density change. The layout has
  // the exact extent of every date/photo/spacer row, including offscreen rows.
  double get _maxScrollOffset => !_scroll.hasClients || _rows.isEmpty
      ? 0
      : math.max(
          0,
          _rows.last.offset +
              _rows.last.extent -
              _scroll.position.viewportDimension,
        );

  void _save() {
    final position = widget.position;
    if (position != null) {
      position.anchor = _anchor;
      position.relative = _relative;
      position.order = _oldOrder;
    }
  }

  @override
  void dispose() {
    _minute?.cancel();
    _blurEpoch++;
    _blurSettle?.cancel();
    _blurDeadline?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.browser.removeListener(_blurAccessChanged);
    _images?.visibleDetailsReady.removeListener(_restoreReadyBlur);
    _glassChanges.dispose();
    for (final position in _scroll.positions) {
      position.isScrollingNotifier.removeListener(_imageScrollState);
    }
    _images?.detachWindow(this);
    if (_ownsImages) _images?.dispose();
    _sweepTicker.dispose();
    _selectionChanged.dispose();
    _save();
    _scroll.dispose();
    super.dispose();
  }

  TextStyle get _dateStyle =>
      (Theme.of(context).textTheme.labelMedium ?? const TextStyle()).copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 19 / 14,
      );

  Locale? _lastLocale;
  String _dateLabel(String day) {
    final date = DateTime.tryParse(day);
    return date == null
        ? context.tr(day)
        : context.tr('{0}年{1}月{2}日', [date.year, date.month, date.day]);
  }

  void _layout(
    List<Photo> photos,
    double width,
    int columns, {
    required double topInset,
    required double bottomInset,
  }) {
    final locale = Localizations.localeOf(context);
    final zone = DateTime.now().timeZoneOffset.toString();
    final textScaler = MediaQuery.textScalerOf(context);
    final dateStyle = _dateStyle;
    if ((_lastPhotos != null && listEquals(photos, _lastPhotos)) &&
        width == _lastWidth &&
        columns == _lastColumns &&
        textScaler == _lastTextScaler &&
        dateStyle == _lastDateStyle &&
        topInset == _gridTopInset &&
        _pendingPinchCenter == null &&
        locale == _lastLocale &&
        zone == _lastZone) {
      if (bottomInset != _gridBottomInset) {
        // Selection changes only the footer clearance. Keep the mounted list,
        // its scroll position and decoded tiles; a new layout key would tear
        // down the scrolling subtree and schedule an unnecessary anchor jump.
        if (_gridBottomInset > 0) _rows.removeLast();
        if (bottomInset > 0) {
          final end = _rows.isEmpty
              ? 0.0
              : _rows.last.offset + _rows.last.extent;
          _rows.add(_Row(end, bottomInset, null, const []));
        }
        _gridBottomInset = bottomInset;
      }
      return;
    }
    // User scrolling owns the anchor. Partial refresh batches must not replace
    // an anchor whose photo has not arrived yet.
    if (_sweepPoint != null && !listEquals(photos, _sweepPhotos)) {
      _stopSweep();
    }
    _layoutRevision++;
    _lastPhotos = photos;
    _lastWidth = width;
    _lastZone = zone;
    _lastLocale = locale;
    _lastColumns = columns;
    _lastTextScaler = textScaler;
    _lastDateStyle = dateStyle;
    _gridTopInset = topInset;
    _gridBottomInset = bottomInset;
    final cell = (width - (columns - 1) * _gap) / columns;
    final rows = <_Row>[];
    var offset = topInset;
    if (topInset > 0) rows.add(_Row(0, topInset, null, const []));
    var index = 0;
    while (index < photos.length) {
      final day = viewDay(photos[index], widget.view);
      final label = _dateLabel(day);
      final painter = TextPainter(
        text: TextSpan(text: label, style: dateStyle),
        textDirection: Directionality.of(context),
        textScaler: textScaler,
      )..layout(maxWidth: math.max(1, width - 24));
      final headerHeight = math.max(28.0, painter.height + 10);
      painter.dispose();
      rows.add(_Row(offset, headerHeight, label, const []));
      offset += headerHeight;
      final group = <Photo>[];
      while (index < photos.length &&
          viewDay(photos[index], widget.view) == day) {
        group.add(photos[index++]);
      }
      for (var i = 0; i < group.length; i += columns) {
        final end = (i + columns).clamp(0, group.length);
        rows.add(_Row(offset, cell + _gap, null, group.sublist(i, end)));
        offset += cell + _gap;
      }
    }
    if (bottomInset > 0) {
      rows.add(_Row(offset, bottomInset, null, const []));
    }
    final newKeys = photos.map((photo) => photo.key).toSet();
    if (_anchor != null &&
        !newKeys.contains(_anchor) &&
        widget.browser.phase == BrowsePhase.ready) {
      final previous = _oldOrder.indexOf(_anchor!);
      String? nearest;
      for (var distance = 1; distance <= _oldOrder.length; distance++) {
        for (final candidate in [previous + distance, previous - distance]) {
          if (candidate >= 0 &&
              candidate < _oldOrder.length &&
              newKeys.contains(_oldOrder[candidate])) {
            nearest = _oldOrder[candidate];
            break;
          }
        }
        if (nearest != null) break;
      }
      _anchor = nearest;
    }
    _rows = rows;
    if (widget.browser.phase == BrowsePhase.ready) {
      _oldOrder = photos.map((p) => p.key).toList();
    }
    final matches = rows.where(
      (row) => row.photos.any((p) => p.key == _anchor),
    );
    final preserveCenter = _pendingPinchCenter != null && matches.isNotEmpty;
    if (preserveCenter) {
      _relative = _pendingPinchCenter! - (matches.first.extent - _gap) / 2;
    }
    _pendingPinchCenter = null;
    _save();
    final target = matches.isEmpty ? 0.0 : matches.first.offset - _relative;
    _restoring = true;
    final revision = _layoutRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _layoutRevision) return;
      if (_scroll.hasClients) {
        final destination = target.clamp(0.0, _maxScrollOffset);
        _scroll.jumpTo(destination);
        if (preserveCenter) {
          _relative = matches.first.offset - destination;
          _save();
        }
      }
      _restoring = false;
    });
  }

  Future<Rect?> _locate(String key) async {
    if (!mounted) return null;
    var row = _rows.where((r) => r.photos.any((p) => p.key == key));
    final missing = row.isEmpty;
    if (missing) {
      final index = _viewerOrder.indexOf(key);
      for (var distance = 1; distance < _viewerOrder.length; distance++) {
        for (final i in [index + distance, index - distance]) {
          if (i < 0 || i >= _viewerOrder.length) continue;
          final candidate = _rows.where(
            (r) => r.photos.any((p) => p.key == _viewerOrder[i]),
          );
          if (candidate.isNotEmpty) {
            key = _viewerOrder[i];
            row = candidate;
            break;
          }
        }
        if (row.isNotEmpty) break;
      }
    }
    if (row.isEmpty || !_scroll.hasClients) return null;
    final targetRow = row.first;
    final position = _scroll.position;
    // Only the photo, excluding its gap, must fit between the overlay bars.
    final alreadyVisible =
        !missing &&
        targetRow.offset >= position.pixels + _gridTopInset &&
        targetRow.offset + targetRow.extent - _gap <=
            position.pixels + position.viewportDimension - _gridBottomInset;
    _anchor = key;
    final destination = alreadyVisible
        ? position.pixels
        : (targetRow.offset - _gridTopInset).clamp(0.0, _maxScrollOffset);
    _relative = targetRow.offset - destination;
    _save();
    if (!alreadyVisible) _scroll.jumpTo(destination);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return null;
    final box = _tileKeys[key]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    return missing ? null : box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _open(Photo photo, List<Photo> photos) async {
    if (_blockedSequence ||
        _viewerOpen ||
        widget.browser.phase != BrowsePhase.ready) {
      return;
    }
    final box = _tileKeys[photo.key]?.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    _viewerOpen = true;
    _viewerOrder = photos.map((p) => p.key).toList();
    await Navigator.of(context).push<String>(
      PageRouteBuilder<String>(
        opaque: false,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (context, _, _) => PhotoViewer(
          browser: widget.browser,
          favorites: widget.favorites,
          onPhysicalAction: widget.physical == null
              ? null
              : (photo, kind) => _operation([photo], kind),
          photos: photos,
          initialKey: photo.key,
          origin: box.localToGlobal(Offset.zero) & box.size,
          locate: _locate,
        ),
      ),
    );
    _viewerOpen = false;
  }

  Rect? get _sweepViewport {
    final box = _gridGestureKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    final origin = box.localToGlobal(Offset.zero);
    return Rect.fromLTWH(
      origin.dx,
      origin.dy + _gridTopInset,
      box.size.width,
      math.max(0, box.size.height - _gridTopInset - _gridBottomInset),
    );
  }

  void _startSweep(Photo photo, Offset position) {
    if (_blockedSequence ||
        _viewerOpen ||
        widget.browser.phase != BrowsePhase.ready) {
      return;
    }
    final photos = _lastPhotos;
    if (photos == null) return;
    final anchor = photos.indexWhere((p) => p.key == photo.key);
    if (anchor < 0) return;
    _sweepPhotos = List.of(photos);
    _sweepIndices
      ..clear()
      ..addEntries(
        photos.indexed.map((entry) => MapEntry(entry.$2.key, entry.$1)),
      );
    _sweepBaseline
      ..clear()
      ..addAll(_selectedPhotos);
    _sweepAnchor = _sweepEnd = anchor;
    _selectionWarning = null;
    _sweepAdd = !_selectedPhotos.contains(photo.key);
    _sweepGeneration = widget.browser.generation;
    _sweepPoint = position;
    _sweepElapsed = Duration.zero;
    setState(() {
      _selecting = true;
      _selectionWarning = null;
      _selectionGeneration = widget.browser.generation;
      _applySweepIndex(anchor, true);
    });
    _sweepTicker.start();
  }

  bool _applySweepIndex(int index, bool inRange) {
    final photo = _sweepPhotos[index];
    final selected = inRange ? _sweepAdd : _sweepBaseline.contains(photo.key);
    if (selected) {
      _selectionIdentities[photo.key] = favoriteIdentity(
        photo,
        widget.browser.libraryVersion,
      );
      return _selectedPhotos.add(photo.key);
    }
    _selectionIdentities.remove(photo.key);
    return _selectedPhotos.remove(photo.key);
  }

  void _setSweepEnd(Photo photo) {
    final end = _sweepIndices[photo.key];
    if (end == null || end == _sweepEnd) return;
    final oldLow = math.min(_sweepAnchor, _sweepEnd);
    final oldHigh = math.max(_sweepAnchor, _sweepEnd);
    final low = math.min(_sweepAnchor, end);
    final high = math.max(_sweepAnchor, end);
    var changed = false;
    // Only the symmetric difference changes; the baseline is copied once.
    for (var i = math.min(oldLow, low); i < math.max(oldLow, low); i++) {
      changed = _applySweepIndex(i, i >= low && i <= high) || changed;
    }
    for (
      var i = math.min(oldHigh, high) + 1;
      i <= math.max(oldHigh, high);
      i++
    ) {
      changed = _applySweepIndex(i, i >= low && i <= high) || changed;
    }
    _sweepEnd = end;
    if (changed) _selectionChanged.value++;
  }

  void _stopSweep() {
    _sweepTicker.stop();
    _sweepPoint = null;
    _sweepPhotos = const [];
    _sweepIndices.clear();
    _sweepBaseline.clear();
    _sweepGeneration = null;
  }

  void _sweepTo(Offset point, {bool afterScroll = false}) {
    if (_sweepPoint == null) return;
    if (widget.browser.phase != BrowsePhase.ready ||
        widget.browser.generation != _sweepGeneration) {
      _stopSweep();
      return;
    }
    _sweepPoint = point;
    final viewport = _sweepViewport;
    final box = _gridGestureKey.currentContext?.findRenderObject();
    if (viewport == null ||
        !viewport.contains(point) ||
        box is! RenderBox ||
        !_scroll.hasClients ||
        _lastColumns <= 0) {
      return;
    }
    final local = box.globalToLocal(point) + Offset(0, _scroll.offset);
    final cell = (_lastWidth - (_lastColumns - 1) * _gap) / _lastColumns;
    final col = (local.dx / (cell + _gap)).floor();
    if (col < 0 || col >= _lastColumns) return;
    var low = 0, high = _rows.length;
    final firstY = afterScroll
        ? box.globalToLocal(viewport.topLeft).dy + _scroll.offset
        : local.dy;
    final lastY = afterScroll
        ? box.globalToLocal(viewport.bottomRight).dy + _scroll.offset
        : local.dy;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_rows[mid].offset + _rows[mid].extent < firstY) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    Photo? nearest;
    var distance = double.infinity;
    for (
      var index = low;
      index < _rows.length && _rows[index].offset <= lastY;
      index++
    ) {
      final row = _rows[index];
      if (col >= row.photos.length) continue;
      final rect = Rect.fromLTWH(col * (cell + _gap), row.offset, cell, cell);
      if (rect.contains(local)) {
        _setSweepEnd(row.photos[col]);
        return;
      }
      if (afterScroll && rect.bottom > firstY && rect.top < lastY) {
        final delta = (rect.center.dy - local.dy).abs();
        if (delta < distance) {
          nearest = row.photos[col];
          distance = delta;
        }
      }
    }
    // Manual movement through gaps/date headings holds the last endpoint.
    if (nearest != null) _setSweepEnd(nearest);
  }

  void _sweepScroll(double seconds) {
    final point = _sweepPoint;
    final viewport = _sweepViewport;
    if (point == null || viewport == null || !_scroll.hasClients) return;
    if (widget.browser.phase != BrowsePhase.ready ||
        widget.browser.generation != _sweepGeneration) {
      _stopSweep();
      return;
    }
    if (!viewport.contains(point)) return;
    final edge = math.min(48.0, viewport.height / 3);
    if (edge <= 0) return;
    final top = point.dy - viewport.top, bottom = viewport.bottom - point.dy;
    final speed = top < edge
        ? -480 * (1 - top / edge)
        : bottom < edge
        ? 480 * (1 - bottom / edge)
        : 0.0;
    final next = (_scroll.offset + speed * seconds).clamp(
      0.0,
      _maxScrollOffset,
    );
    if (next == _scroll.offset) return;
    _scroll.jumpTo(next);
    _sweepTo(point, afterScroll: true);
  }

  Widget _selectionBuilder(Widget Function() builder) =>
      ValueListenableBuilder<int>(
        valueListenable: _selectionChanged,
        builder: (_, _, _) => builder(),
      );

  void _select(Photo photo) {
    if (_blockedSequence || widget.browser.phase != BrowsePhase.ready) return;
    setState(() {
      _selecting = true;
      _selectionWarning = null;
      _selectionGeneration = widget.browser.generation;
      if (!_selectedPhotos.add(photo.key)) _selectedPhotos.remove(photo.key);
      _selectionIdentities[photo.key] = favoriteIdentity(
        photo,
        widget.browser.libraryVersion,
      );
    });
  }

  Future<void> _operation(List<Photo> photos, PhysicalKind kind) async {
    _stopSweep();
    if (!mounted || widget.physical == null || photos.isEmpty) return;
    final result = await showMediaOperationDialog(
      context,
      operations: widget.physical!,
      photos: photos,
      kind: kind,
    );
    if (mounted && result != null) {
      setState(() {
        _selectedPhotos.clear();
        _selecting = false;
      });
    }
  }

  void _toggleSelection() {
    _stopSweep();
    setState(() {
      _selectionWarning = null;
      _selecting = !_selecting;
      _selectedPhotos.clear();
      _selectionGeneration = widget.browser.generation;
    });
  }

  String _countLabel(int count) {
    final browser = widget.browser;
    if (browser.phase == BrowsePhase.checking) return context.tr('正在核对媒体权限');
    if (browser.phase == BrowsePhase.loading) {
      return browser.updating
          ? context.tr('更新中 · 上次 {0} 项', [count])
          : context.tr('读取中 · 已加载 {0} 项', [count]);
    }
    if (browser.phase == BrowsePhase.denied ||
        browser.phase == BrowsePhase.idle) {
      return context.tr('尚未授权媒体访问');
    }
    if (browser.phase == BrowsePhase.failed) return context.tr('媒体读取失败');
    if (count == 0 && widget.emptyContent != null) return context.tr('目录状态');
    return browser.access == PhotoAccess.limited
        ? context.tr('{0} 项 · 访问范围受限', [count])
        : context.tr('{0} 项', [count]);
  }

  Widget _gridGlass({required Widget child}) => ListenableBuilder(
    listenable: _glassChanges,
    child: child,
    builder: (context, child) => GlassSurface(
      enabled: widget.glassEnabled && !_gridBlurSuspended,
      borderRadius: BorderRadius.circular(20),
      child: child!,
    ),
  );

  Widget _scopeBar(List<Photo> photos) {
    final enabled =
        widget.browser.phase == BrowsePhase.ready && photos.isNotEmpty;
    final title = _selecting
        ? context.tr('已选 {0} 项', [_selectedPhotos.length])
        : widget.scopeTitle!;
    return _gridGlass(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            if (widget.navigationButton != null)
              SizedBox(width: 48, child: widget.navigationButton),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tooltip(
                      message: title,
                      child: Text(
                        title,
                        maxLines:
                            MediaQuery.textScalerOf(context).scale(17) > 22
                            ? 2
                            : 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          height: 22 / 17,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _selecting
                          ? context.selectionSummary(
                              photos.where(
                                (p) => _selectedPhotos.contains(p.key),
                              ),
                            )
                          : _countLabel(photos.length),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 17 / 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_selecting) ...[
              IconButton(
                tooltip: context.tr('退出选择'),
                onPressed: _toggleSelection,
                icon: const Icon(Icons.close),
              ),
              Tooltip(
                message: context.tr('全选当前列表'),
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  onPressed: enabled
                      ? () => setState(
                          () =>
                              _selectedPhotos.addAll(photos.map((p) => p.key)),
                        )
                      : null,
                  child: Text(context.tr('全选')),
                ),
              ),
            ] else ...[
              if (widget.physical != null)
                IconButton(
                  tooltip: context.tr('选择媒体'),
                  onPressed: enabled ? _toggleSelection : null,
                  icon: const Icon(Icons.check_box_outlined, size: 22),
                ),
              if (widget.menuButton != null)
                SizedBox(width: 48, child: widget.menuButton),
            ],
          ],
        ),
      ),
    );
  }

  Widget _standaloneSelectionBar(List<Photo> photos) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      TextButton(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: widget.browser.phase == BrowsePhase.ready
            ? _toggleSelection
            : null,
        child: Text(_selecting ? context.tr('退出选择') : context.tr('选择媒体')),
      ),
      if (_selecting) ...[
        Text(context.tr('已选 {0} 项', [_selectedPhotos.length])),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () =>
              setState(() => _selectedPhotos.addAll(photos.map((p) => p.key))),
          child: Text(context.tr('全选当前列表')),
        ),
      ],
    ],
  );

  Widget _selectionActions(List<Photo> photos) {
    final physical = widget.physical!;
    final enabled =
        _selectedPhotos.isNotEmpty &&
        widget.browser.phase == BrowsePhase.ready &&
        !physical.busy &&
        !physical.blocked &&
        !physical.guard.held;
    List<Photo> selected() =>
        photos.where((p) => _selectedPhotos.contains(p.key)).toList();
    return _gridGlass(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            Expanded(
              child: TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: enabled
                    ? () => _operation(selected(), PhysicalKind.move)
                    : null,
                icon: const Icon(Icons.drive_file_move_outline),
                label: Text(context.tr('移动')),
              ),
            ),
            Expanded(
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: enabled
                    ? () => _operation(selected(), PhysicalKind.delete)
                    : null,
                icon: const Icon(Icons.delete_outline),
                label: Text(context.tr('删除')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grid(
    List<Photo> photos, {
    required double topInset,
    required double bottomInset,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final preferred =
          widget.density.index +
          (MediaQuery.orientationOf(context) == Orientation.portrait ? 3 : 5);
      final fit = math.max(
        1,
        ((constraints.maxWidth + _gap) / (_minimumTile + _gap)).floor(),
      );
      final columns = math.min(preferred, fit);
      _layout(
        photos,
        constraints.maxWidth,
        columns,
        topInset: topInset,
        bottomInset: bottomInset,
      );
      final cell = (constraints.maxWidth - (columns - 1) * _gap) / columns;
      _viewportHeight = constraints.maxHeight;
      _cell = cell;
      _updateImageWindow();
      return Listener(
        key: _gridGestureKey,
        behavior: HitTestBehavior.opaque,
        onPointerDown: _pointerDown,
        onPointerMove: _pointerMove,
        onPointerUp: _pointerEnd,
        onPointerCancel: _pointerEnd,
        child: RefreshIndicator(
          edgeOffset: topInset,
          onRefresh: () async {
            if (!_blockedSequence) await widget.browser.refresh();
          },
          child: KeyedSubtree(
            key: ValueKey(_layoutRevision),
            child: ListView.builder(
              key: const ValueKey('photo-grid'),
              padding: EdgeInsets.zero,
              controller: _scroll,
              physics: _multiTouch
                  ? const NeverScrollableScrollPhysics()
                  : const AlwaysScrollableScrollPhysics(),
              scrollCacheExtent: ScrollCacheExtent.pixels(
                constraints.maxHeight,
              ),
              itemCount: _rows.length,
              // Deep anchor restoration must not lay out every preceding tile.
              // Headers, media rows and insets already have exact extents.
              itemExtentBuilder: (index, _) =>
                  index < _rows.length ? _rows[index].extent : null,
              itemBuilder: (context, index) {
                final row = _rows[index];
                if (row.day != null) {
                  return SizedBox(
                    height: row.extent,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(row.day!, style: _dateStyle),
                      ),
                    ),
                  );
                }
                return SizedBox(
                  height: row.extent,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Row(
                      children: [
                        for (var i = 0; i < row.photos.length; i++) ...[
                          if (i > 0) const SizedBox(width: _gap),
                          SizedBox(
                            width: cell,
                            height: cell,
                            child: GestureDetector(
                              key: _tileKeys.putIfAbsent(
                                row.photos[i].key,
                                GlobalKey.new,
                              ),
                              onTap: () => _selecting
                                  ? _select(row.photos[i])
                                  : _open(row.photos[i], photos),
                              // Both axes compete with the parent scroll at the
                              // same threshold. Only selection mode claims drags;
                              // title/blank-space drags still reach the list.
                              dragStartBehavior: DragStartBehavior.down,
                              onHorizontalDragStart: !_selecting
                                  ? null
                                  : (details) => _startSweep(
                                      row.photos[i],
                                      details.globalPosition,
                                    ),
                              onVerticalDragStart: !_selecting
                                  ? null
                                  : (details) => _startSweep(
                                      row.photos[i],
                                      details.globalPosition,
                                    ),
                              onHorizontalDragUpdate: !_selecting
                                  ? null
                                  : (details) =>
                                        _sweepTo(details.globalPosition),
                              onVerticalDragUpdate: !_selecting
                                  ? null
                                  : (details) =>
                                        _sweepTo(details.globalPosition),
                              onLongPressStart: widget.physical == null
                                  ? null
                                  : (details) => _startSweep(
                                      row.photos[i],
                                      details.globalPosition,
                                    ),
                              child: ValueListenableBuilder<int>(
                                valueListenable: _selectionChanged,
                                child: PhotoTile(
                                  key: ValueKey(
                                    '${widget.browser.imageGeneration}:${row.photos[i].key}',
                                  ),
                                  browser: widget.browser,
                                  photo: row.photos[i],
                                  size: cell,
                                  images: _images,
                                ),
                                builder: (context, _, image) => Semantics(
                                  selected: _selecting
                                      ? _selectedPhotos.contains(
                                          row.photos[i].key,
                                        )
                                      : null,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      image!,
                                      if (_selecting)
                                        Positioned(
                                          top: 4,
                                          right: 4,
                                          child: DecoratedBox(
                                            decoration: BoxDecoration(
                                              color:
                                                  _selectedPhotos.contains(
                                                    row.photos[i].key,
                                                  )
                                                  ? Theme.of(context)
                                                        .colorScheme
                                                        .primary
                                                  : const Color(0xCC172033),
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: Colors.white,
                                                width: 1.5,
                                              ),
                                            ),
                                            child: Padding(
                                              padding: const EdgeInsets.all(2),
                                              child: Icon(
                                                _selectedPhotos.contains(
                                                      row.photos[i].key,
                                                    )
                                                    ? Icons.check
                                                    : Icons.circle_outlined,
                                                size: 18,
                                                color:
                                                    _selectedPhotos.contains(
                                                      row.photos[i].key,
                                                    )
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .onPrimary
                                                    : Colors.white,
                                                semanticLabel:
                                                    _selectedPhotos.contains(
                                                      row.photos[i].key,
                                                    )
                                                    ? context.tr('已选择')
                                                    : context.tr('未选择'),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.browser,
      widget.favorites,
      widget.physical,
    ]),
    builder: (context, _) {
      final browser = widget.browser;
      if (browser.phase != BrowsePhase.ready ||
          _selectionGeneration != browser.generation) {
        _stopSweep();
      }
      final photos = widget.albumKey == null
          ? viewPhotos(
              browser.photos,
              widget.view,
              widget.favorites,
              DateTime.now(),
            )
          : browser.photos.where((p) => p.albumKey == widget.albumKey).toList();
      if (browser.phase == BrowsePhase.ready) {
        final current = {for (final photo in photos) photo.key: photo};
        if (_selectionGeneration != null &&
            _selectionGeneration != browser.generation) {
          final previousCount = _selectedPhotos.length;
          _selectedPhotos.removeWhere((key) {
            final photo = current[key];
            final previous = _selectionIdentities[key];
            return photo == null ||
                previous == null ||
                previous != favoriteIdentity(photo, browser.libraryVersion);
          });
          if (_selectedPhotos.length != previousCount) {
            _selectionWarning = _selectedPhotos.isEmpty
                ? '媒体已变化，请重新选择'
                : '部分媒体已失效，已移出选择';
          }
        }
        _selectedPhotos.retainAll(current.keys);
        _selectionIdentities
          ..clear()
          ..addEntries(
            _selectedPhotos.map(
              (key) => MapEntry(
                key,
                favoriteIdentity(current[key]!, browser.libraryVersion),
              ),
            ),
          );
        _selectionGeneration = browser.generation;
      } else if (browser.phase == BrowsePhase.denied ||
          browser.phase == BrowsePhase.failed) {
        _selectedPhotos.clear();
        _selectionIdentities.clear();
        _selecting = false;
      }
      Widget? status;
      if (browser.phase == BrowsePhase.ready &&
          widget.view == LibraryView.favorite) {
        final favorites = widget.favorites;
        if (favorites == null ||
            favorites.phase != FavoritePhase.ready ||
            !favorites.identityAvailable) {
          _selectedPhotos.clear();
          _selecting = false;
          status = Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  favorites?.phase == FavoritePhase.loading
                      ? context.tr('正在读取收藏…')
                      : favorites?.phase == FavoritePhase.failed
                      ? context.tr('私有收藏读取失败')
                      : context.tr('媒体身份暂不可核验'),
                ),
                TextButton(
                  onPressed: () {
                    favorites?.load();
                    browser.refresh();
                  },
                  child: Text(context.tr('重试')),
                ),
              ],
            ),
          );
        }
      }
      if (photos.isEmpty) {
        if (browser.phase == BrowsePhase.ready) {
          status ??= widget.emptyContent;
        }
        status ??= MediaStatus(
          browser: browser,
          missingAlbum: widget.albumKey != null,
          emptyMessage:
              widget.view == LibraryView.videos &&
                  browser.permissions.videos == PhotoAccess.denied
              ? context.tr('未获视频访问权限，请在系统设置中授权')
              : widget.view == LibraryView.images &&
                    browser.permissions.images == PhotoAccess.denied
              ? context.tr('未获图片访问权限，请在系统设置中授权')
              : widget.view == LibraryView.favorite
              ? widget.favorites?.systemMode == true
                    ? context.tr('当前没有可访问的收藏图片或视频')
                    : widget.favorites?.syncAvailable == true
                    ? context.tr('尚无可访问的应用内收藏')
                    : context.tr('尚无可访问的应用内收藏 · 系统互通尚未验证')
              : widget.view == LibraryView.recent
              ? context.tr('最近 30 天没有新加入的媒体')
              : null,
        );
      }
      return PopScope<Object?>(
        canPop: !_selecting,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop &&
              _selecting &&
              ModalRoute.of(context)?.isCurrent == true) {
            _toggleSelection();
          }
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final integrated = widget.scopeTitle != null;
            final scaler = MediaQuery.textScalerOf(context);
            final actionCount = _selecting
                ? 2
                : (widget.physical == null ? 0 : 1) +
                      (widget.menuButton == null ? 0 : 1);
            final textWidth = math.max(
              1.0,
              constraints.maxWidth -
                  (_selecting
                      ? math.max(0.0, scaler.scale(16) * 2 + 8 - 48)
                      : 0) -
                  32 -
                  48 *
                      (actionCount + (widget.navigationButton == null ? 0 : 1)),
            );
            double heightFor(String text, TextStyle style, {int maxLines = 2}) {
              final painter = TextPainter(
                text: TextSpan(text: text, style: style),
                textDirection: Directionality.of(context),
                textScaler: scaler,
                maxLines: maxLines,
              )..layout(maxWidth: textWidth);
              final height = painter.height.ceilToDouble();
              painter.dispose();
              return height;
            }

            final inherited = DefaultTextStyle.of(context).style;
            final barHeight = math.max(
              56.0,
              heightFor(
                    _selecting
                        ? context.tr('已选 {0} 项', [photos.length])
                        : widget.scopeTitle ?? '',
                    inherited.copyWith(
                      fontSize: 17,
                      height: 22 / 17,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: scaler.scale(17) > 22 ? 2 : 1,
                  ) +
                  heightFor(
                    _selecting
                        ? context.selectionSummary(photos)
                        : _countLabel(photos.length),
                    inherited.copyWith(fontSize: 12, height: 17 / 12),
                  ) +
                  12,
            );
            final footerHeight = math.max(
              56.0,
              scaler.scale(16) * (22 / 16) + 32,
            );
            final topInset = integrated ? barHeight + 16 : 0.0;
            final bottomInset = _selecting ? footerHeight + 16 : 0.0;
            return Listener(
              onPointerDown: (event) {
                if (_sweepPoint != null) {
                  final viewport = _sweepViewport;
                  if (viewport == null || !viewport.contains(event.position)) {
                    _stopSweep();
                  }
                }
              },
              child: Column(
                children: [
                  if (_selectionWarning != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: Text(context.tr(_selectionWarning!)),
                    ),
                  if (!integrated && photos.isNotEmpty)
                    MediaSummary(browser: browser, count: photos.length),
                  if (!integrated &&
                      widget.physical != null &&
                      photos.isNotEmpty)
                    _selectionBuilder(() => _standaloneSelectionBar(photos)),
                  if (widget.view == LibraryView.favorite && status == null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                      child: Text(
                        widget.favorites?.systemMode == true
                            ? context.tr('图片收藏与系统相册互通，视频使用应用内收藏。')
                            : widget.favorites?.syncAvailable == true
                            ? context.tr('应用内收藏')
                            : context.tr('应用内收藏 · 系统相册互通尚未验证'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  if (integrated &&
                      browser.access == PhotoAccess.limited &&
                      photos.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              context.accessDescription(browser.permissions),
                            ),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: () => browser.refresh(reselect: true),
                            child: Text(context.tr('重新选择')),
                          ),
                        ],
                      ),
                    ),
                  if (integrated &&
                      browser.failure != null &&
                      browser.phase == BrowsePhase.ready)
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: Text(context.tr('更新失败，显示上次确认的媒体，请重试')),
                    ),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: status == null
                              ? _grid(
                                  photos,
                                  topInset: topInset,
                                  bottomInset: bottomInset,
                                )
                              : Padding(
                                  padding: EdgeInsets.only(
                                    top: topInset,
                                    bottom: bottomInset,
                                  ),
                                  child: status,
                                ),
                        ),
                        if (integrated)
                          Positioned(
                            top: 8,
                            left: 8,
                            right: 8,
                            height: barHeight,
                            child: _selectionBuilder(() => _scopeBar(photos)),
                          ),
                        if (_selecting)
                          Positioned(
                            left: 8,
                            right: 8,
                            bottom: 8,
                            height: footerHeight,
                            child: _selectionBuilder(
                              () => _selectionActions(photos),
                            ),
                          ),
                        if (integrated && browser.phase == BrowsePhase.loading)
                          Positioned(
                            top: topInset - 4,
                            left: 20,
                            right: 20,
                            child: const LinearProgressIndicator(minHeight: 2),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    },
  );
}

class _Row {
  _Row(this.offset, this.extent, this.day, this.photos);
  final double offset, extent;
  final String? day;
  final List<Photo> photos;
}

class MediaSummary extends StatelessWidget {
  const MediaSummary({super.key, required this.browser, required this.count});
  final PhotoBrowser browser;
  final int count;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                browser.phase == BrowsePhase.loading
                    ? browser.updating
                          ? context.tr('更新中 · 上次 {0} 项', [count])
                          : context.tr('读取中 · 已加载 {0} 项', [count])
                    : context.tr('{0} 项', [count]),
              ),
            ),
            IconButton(
              tooltip: context.tr('刷新'),
              onPressed: browser.refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (browser.access == PhotoAccess.limited)
          Row(
            children: [
              Expanded(
                child: Text(context.accessDescription(browser.permissions)),
              ),
              TextButton(
                onPressed: () => browser.refresh(reselect: true),
                child: Text(context.tr('重新选择')),
              ),
            ],
          ),
        SizedBox(
          height: 4,
          child: browser.phase == BrowsePhase.loading
              ? const LinearProgressIndicator()
              : null,
        ),
        if (browser.failure != null && browser.phase == BrowsePhase.ready)
          Text(context.tr('更新失败，显示上次确认的媒体，请重试')),
      ],
    ),
  );
}

class MediaStatus extends StatelessWidget {
  const MediaStatus({
    super.key,
    required this.browser,
    this.missingAlbum = false,
    this.emptyMessage,
  });
  final PhotoBrowser browser;
  final bool missingAlbum;
  final String? emptyMessage;
  @override
  Widget build(BuildContext context) {
    final loading =
        browser.phase == BrowsePhase.checking ||
        browser.phase == BrowsePhase.loading;
    final denied =
        browser.phase == BrowsePhase.denied ||
        browser.phase == BrowsePhase.idle;
    final text = loading
        ? context.tr('正在读取媒体…')
        : denied
        ? context.tr('访问媒体以浏览本机图片和视频')
        : browser.phase == BrowsePhase.failed
        ? browser.failure == MediaFailureKind.attribution
              ? context.tr('相册归属读取异常，请重试')
              : context.tr('媒体读取失败，请重试')
        : missingAlbum
        ? context.tr('相册当前不可访问')
        : emptyMessage != null
        ? emptyMessage!
        : browser.access == PhotoAccess.limited
        ? context.tr('所选范围内没有可访问的图片')
        : context.tr('没有媒体');
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.photo_library_outlined, size: 56),
            const SizedBox(height: 20),
            Text(text, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            if (loading)
              const CircularProgressIndicator()
            else ...[
              if (denied) ...[
                Text(context.tr('仅用于读取图片、视频和相册；此授权本身不修改文件。')),
                FilledButton(
                  onPressed: () => browser.refresh(request: true),
                  child: Text(context.tr('访问媒体')),
                ),
                TextButton(
                  onPressed: browser.source.openSettings,
                  child: Text(context.tr('打开设置')),
                ),
              ] else ...[
                if (browser.access == PhotoAccess.limited) ...[
                  Text(context.accessDescription(browser.permissions)),
                  TextButton(
                    onPressed: () => browser.refresh(reselect: true),
                    child: Text(context.tr('重新选择')),
                  ),
                ],
                TextButton(
                  onPressed: browser.refresh,
                  child: Text(context.tr('重试 / 刷新')),
                ),
                if (missingAlbum)
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(context.tr('返回根目录')),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class PhotoTile extends StatefulWidget {
  const PhotoTile({
    super.key,
    required this.browser,
    required this.photo,
    required this.size,
    this.isPriority,
    this.images,
  });
  final PhotoBrowser browser;
  final Photo photo;
  final double size;
  final bool Function()? isPriority;
  final ThumbnailImages? images;
  @override
  State<PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<PhotoTile> {
  ThumbnailImages? _images;
  bool _ownsImages = false;
  ThumbnailFrame? _frame;
  int _pixels = 0;
  bool _traced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_images == null) {
      _images =
          widget.images ??
          ThumbnailScope.maybeOf(context) ??
          ThumbnailImages(widget.browser);
      _ownsImages =
          widget.images == null && ThumbnailScope.maybeOf(context) == null;
      _images!.addImageListener(widget.photo.key, _changed);
    }
    _pixels = (widget.size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 512);
    if (widget.images == null) {
      _images!.attachCover(this, widget.photo, _pixels);
    }
    _readFrame();
  }

  @override
  void didUpdateWidget(PhotoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photo.key != widget.photo.key) {
      _images!.removeImageListener(oldWidget.photo.key, _changed);
      _images!.addImageListener(widget.photo.key, _changed);
    }
    _pixels = (widget.size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 512);
    if (widget.images == null) {
      _images!.attachCover(this, widget.photo, _pixels);
    }
    _readFrame();
  }

  void _readFrame() {
    final next = _images!.acquire(
      widget.photo,
      _pixels,
      coverOwner: widget.images == null ? this : null,
    );
    _frame?.dispose();
    _frame = next;
  }

  void _changed() {
    if (mounted) setState(_readFrame);
  }

  @override
  void dispose() {
    _images?.removeImageListener(widget.photo.key, _changed);
    _frame?.dispose();
    if (widget.images == null) _images?.detachCover(this);
    if (_ownsImages) _images?.dispose();
    super.dispose();
  }

  Widget _error() => Center(
    child: IconButton(
      tooltip: widget.photo.kind == MediaKind.video
          ? context.tr('视频封面不可用，重试')
          : context.tr('图片不可用，重试'),
      onPressed: () => _images!.retry(
        widget.photo,
        coverOwner: widget.images == null ? this : null,
      ),
      icon: const Icon(Icons.broken_image_outlined),
    ),
  );
  Widget _picture() {
    if (_frame == null) {
      if (_images!.failed(
        widget.photo,
        coverOwner: widget.images == null ? this : null,
      )) {
        return _error();
      }
      return const Center(
        child: Icon(Icons.image_outlined, color: Colors.grey),
      );
    }
    if (!_traced) {
      _traced = true;
      traceThumbnail(widget.photo.key, context);
    }
    return RawImage(
      image: _frame!.image,
      fit: BoxFit.cover,
      width: widget.size,
      height: widget.size,
    );
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        '${widget.photo.kind == MediaKind.video ? context.tr('视频') : context.tr('照片')} ${widget.photo.id}',
    child: ColoredBox(
      color: const Color(0xFFE4E7EF),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _picture(),
          if (_frame != null &&
              _images!.failed(
                widget.photo,
                coverOwner: widget.images == null ? this : null,
              ))
            _error(),
          if (widget.photo.kind == MediaKind.video)
            Positioned(
              right: 2,
              bottom: 2,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.size - 4),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.play_arrow,
                          color: Colors.white,
                          size: 12,
                        ),
                        if (widget.size >= 48)
                          Flexible(
                            child: Text(
                              context.tr(
                                mediaDuration(widget.photo.durationMs),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                height: 15 / 11,
                                fontWeight: FontWeight.w500,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

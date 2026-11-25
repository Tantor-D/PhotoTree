import 'interface_strings.dart';
import '../library/physical_operations.dart';

import 'dart:ui' as ui;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../media/browser.dart';
import '../library/favorites.dart';
import 'favorite_migration_page.dart';
import '../media/media_source.dart';
import '../media/viewer_session.dart';
import '../media/android_video_player.dart';
import 'viewer_motion.dart';
import 'visual_style.dart';
import 'video_playback.dart';

class PhotoViewer extends StatefulWidget {
  const PhotoViewer({
    super.key,
    required this.browser,
    required this.photos,
    required this.initialKey,
    required this.origin,
    required this.locate,
    this.favorites,
    this.onPhysicalAction,
    this.createVideoController = androidVideoController,
  });
  final PhotoBrowser browser;
  final Favorites? favorites;
  final FutureOr<void> Function(Photo, PhysicalKind)? onPhysicalAction;
  final VideoPlayerController Function(Uri) createVideoController;

  final List<Photo> photos;
  final String initialKey;
  final Rect origin;
  final Future<Rect?> Function(String key) locate;
  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final ViewerSession session;
  late final ViewerMotion motion;
  late final VideoPlayback playback;
  bool _operating = false;
  double? _seekPosition;
  final ThemeData _viewerTheme = photoTreeTheme(Brightness.dark);
  bool _toolbar = true, _exited = false, _layingOut = false;
  bool _reduceAnimations = false, _menuOpen = false;
  int _closeTicket = 0;
  (Photo, PhysicalKind)? _requestedOperation;
  bool _openingPending = true;
  Size _size = Size.zero, _imageSize = Size.zero;
  String? _layoutKey;
  ui.FlutterView? _view;
  bool? _landscape;
  Timer? _rotationWindow;
  String? _verifiedVideoIdentity;
  (String, bool)? _rotationResume;
  int _resumeTicket = 0;
  bool get _isLandscape {
    final size = _view?.physicalSize ?? Size.zero;
    return size.width > size.height;
  }

  void _cancelResume() {
    _rotationResume = null;
    _rotationWindow?.cancel();
    _rotationWindow = null;
    _resumeTicket++;
  }

  void _suspendPlayback() {
    _resumeTicket++;
    // The app observer withdraws the browser before our lifecycle callback.
    // Capture the last verified identity before that callback releases playback.
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.inactive &&
        playback.controller?.value.isPlaying == true &&
        _verifiedVideoIdentity != null &&
        _landscape != null &&
        !_operating &&
        !_menuOpen &&
        !_exited) {
      _rotationResume ??= (_verifiedVideoIdentity!, _landscape!);
    }
    unawaited(playback.stop());
  }

  Future<void> _openPlayback(Photo photo, String version, bool resume) async {
    final ticket = _resumeTicket;
    await playback.open(photo, version);
    if (resume &&
        mounted &&
        ticket == _resumeTicket &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        session.verified &&
        session.currentKey == photo.key &&
        !_operating &&
        !_menuOpen &&
        !_exited &&
        playback.controller?.value.isPlaying == false) {
      await playback.toggle();
    }
  }

  @override
  void initState() {
    super.initState();
    session = ViewerSession(widget.browser, widget.photos, widget.initialKey);
    playback = VideoPlayback(
      widget.browser.source,
      createController: widget.createVideoController,
    )..addListener(_playbackChanged);
    WidgetsBinding.instance.addObserver(this);
    motion = ViewerMotion(vsync: this)
      ..onTap = () {
        setState(() => _toolbar = !_toolbar);
      }
      ..onPage = (direction) {
        session.turn(direction);
        motion.resetPhoto(_currentSize);
      }
      ..onDismiss = _close;
    session.addListener(_changed);
    widget.favorites?.addListener(_favoriteChanged);
    motion.addListener(_motionChanged);
    _syncPlayback();
  }

  void _playbackChanged() {
    if (mounted) setState(() {});
  }

  void _syncPlayback() {
    final photo = session.current, version = widget.browser.libraryVersion;
    if (!_operating &&
        session.verified &&
        photo?.kind == MediaKind.video &&
        version != null) {
      final identity = favoriteIdentity(photo!, version);
      final pending = _rotationResume;
      final resume =
          pending != null &&
          pending.$1 == identity &&
          pending.$2 != _isLandscape &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      if (_verifiedVideoIdentity != identity) _cancelResume();
      _rotationResume = null;
      _verifiedVideoIdentity = identity;
      if (pending != null) {
        _rotationWindow?.cancel();
        _rotationWindow = null;
      }
      if (_view != null && _rotationWindow == null) _landscape = _isLandscape;
      unawaited(_openPlayback(photo, version, resume));
    } else {
      if (photo?.kind == MediaKind.image || _operating || session.invalid) {
        _cancelResume();
        unawaited(playback.stop(forget: photo?.kind == MediaKind.image));
      } else {
        _suspendPlayback();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _cancelResume();
    }
    if (state != AppLifecycleState.resumed) _suspendPlayback();
    // Only a verified same-item orientation change can restore play intent.
  }

  @override
  void didChangeMetrics() {
    // Android can report the new size one or more frames before transient
    // focus loss. Keep the prior orientation briefly, not for a later unrelated
    // interruption. Hidden/paused always discard this hint immediately.
    if (_landscape != null &&
        _landscape != _isLandscape &&
        _rotationWindow == null) {
      _rotationWindow = Timer(const Duration(milliseconds: 500), () {
        _rotationWindow = null;
        if (mounted &&
            _rotationResume == null &&
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed) {
          _landscape = _isLandscape;
        }
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.of(context);
    _landscape ??= _isLandscape;
    _reduceAnimations = MediaQuery.disableAnimationsOf(context);
    if (motion.reduceAnimations == _reduceAnimations) return;
    if (motion.animating) {
      // Completing a close/page may navigate or replace the current photo.
      // Do that after dependency-driven build work, never during layout.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) motion.reduceAnimations = _reduceAnimations;
      });
    } else {
      motion.reduceAnimations = _reduceAnimations;
    }
  }

  void _favoriteChanged() {
    if (mounted) setState(() {});
  }

  Size get _currentSize {
    final image = session.image(session.currentKey);
    if (image != null) {
      return Size(image.width.toDouble(), image.height.toDouble());
    }
    final photo = session.current;
    return Size(
      (photo?.width ?? 1).clamp(1, 100000).toDouble(),
      (photo?.height ?? 1).clamp(1, 100000).toDouble(),
    );
  }

  void _motionChanged() {
    if (!mounted || _layingOut) return;
    if (motion.scale > 1.01) session.sharpen();
    setState(() {});
  }

  void _changed() {
    if (!mounted) return;
    _syncPlayback();
    if (!session.verified) motion.suspend();
    if (session.invalid && !_operating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _exit(invalid: true);
      });
    }
    setState(() {});
  }

  Future<void> _close() async {
    _cancelResume();
    await playback.stop();
    if (!mounted) return;
    final ticket = ++_closeTicket;
    final key = session.currentKey;
    final target = await widget.locate(key);
    if (!mounted || ticket != _closeTicket || _exited) return;
    motion.close(target, _exit);
  }

  void _exit({bool invalid = false}) {
    if (_exited || !mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    _exited = true;
    final navigator = Navigator.of(context);
    // Permission loss can invalidate the viewer while its typed menu is open.
    // Dismiss overlays without a result, then return the photo key only to the
    // viewer route; never deliver that String to a PhysicalKind menu route.
    navigator.popUntil((candidate) => identical(candidate, route));
    navigator.pop(session.currentKey);
    final requested = _requestedOperation;
    if (!invalid && requested != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.onPhysicalAction?.call(requested.$1, requested.$2),
      );
    }
    if (invalid) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr('当前媒体已不可访问，请刷新后重试'))));
    }
  }

  @override
  void dispose() {
    _cancelResume();
    WidgetsBinding.instance.removeObserver(this);
    playback.removeListener(_playbackChanged);
    playback.dispose();
    widget.favorites?.removeListener(_favoriteChanged);
    session.removeListener(_changed);
    session.dispose();
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: photoTreeSystemUiStyle(
      Brightness.dark,
      navigationBarColor: Colors.black,
    ),
    child: _viewerContent(context),
  );

  Widget _viewerContent(BuildContext context) => PopScope<String>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _close();
    },
    child: Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final image = _currentSize;
          if (size != _size ||
              _layoutKey != session.currentKey ||
              (image.aspectRatio - _imageSize.aspectRatio).abs() > .001) {
            _size = size;
            _imageSize = image;
            if (_layoutKey != session.currentKey) _seekPosition = null;
            _layoutKey = session.currentKey;
            _layingOut = true;
            motion.layout(
              size,
              image,
              origin: _openingPending ? widget.origin : null,
              startOpening: false,
            );
            _layingOut = false;
          }
          motion.canPrevious = session.neighbor(-1) != null;
          motion.canNext = session.neighbor(1) != null;
          motion.allowZoom = session.current?.kind != MediaKind.video;
          final current = session.image(session.currentKey);
          if (_openingPending &&
              (current != null ||
                  session.errors.containsKey(session.currentKey) ||
                  session.current?.kind == MediaKind.video)) {
            _openingPending = false;
            _layingOut = true;
            motion.animate(
              motion.base,
              duration: const Duration(milliseconds: 260),
            );
            _layingOut = false;
          }
          return Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: motion.background),
                ),
              ),
              Positioned.fill(
                child: Listener(
                  key: const ValueKey('viewer-gesture'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) {
                    _closeTicket++;
                    if (session.verified &&
                        !_openingPending &&
                        _requestedOperation == null) {
                      motion.down(event);
                    }
                  },
                  onPointerMove: (event) {
                    if (session.verified) motion.move(event);
                  },
                  onPointerUp: (event) {
                    if (session.verified) motion.up(event);
                  },
                  onPointerCancel: motion.cancel,
                  child: ClipRect(
                    child: Stack(
                      children: [
                        if (session.verified) ...[
                          for (final direction in [-1, 1])
                            if (motion.page != 0 &&
                                session.neighbor(direction) != null)
                              _frame(
                                session.image(session.neighbor(direction)!),
                                _neighborRect(
                                  session.neighbor(direction)!,
                                  motion.page + direction * size.width,
                                ),
                              ),
                          if (!_openingPending)
                            _frame(
                              current,
                              motion.rect.shift(Offset(motion.page, 0)),
                              isCurrent: true,
                            ),
                        ] else
                          const Center(child: CircularProgressIndicator()),
                      ],
                    ),
                  ),
                ),
              ),
              if (_toolbar && motion.background > .95)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Theme(
                        data: _viewerTheme,
                        child: GlassSurface(
                          key: const ValueKey('viewer-toolbar'),
                          dark: true,
                          enabled: !_menuOpen,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: context.tr('返回媒体网格'),
                                  onPressed: _close,
                                  icon: const Icon(Icons.arrow_back),
                                ),
                                Expanded(
                                  child: Text(
                                    '${session.order.indexOf(session.currentKey) + 1} / ${session.order.length}',
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: PhotoTreeStyle.darkText,
                                      fontSize: 12,
                                      height: 17 / 12,
                                    ),
                                  ),
                                ),
                                _favoriteButton(),
                                if (widget.onPhysicalAction != null)
                                  PopupMenuButton<PhysicalKind>(
                                    tooltip: context.tr('媒体操作'),
                                    enabled:
                                        session.verified &&
                                        session.current != null,
                                    icon: const Icon(Icons.more_horiz),
                                    onOpened: () {
                                      _cancelResume();
                                      setState(() => _menuOpen = true);
                                    },
                                    onCanceled: () {
                                      if (mounted) {
                                        setState(() => _menuOpen = false);
                                      }
                                    },
                                    onSelected: (kind) {
                                      setState(() => _menuOpen = false);
                                      final photo = session.current;
                                      if (!session.verified || photo == null) {
                                        return;
                                      }
                                      if (photo.kind == MediaKind.video) {
                                        unawaited(_videoOperation(photo, kind));
                                      } else {
                                        _requestedOperation = (photo, kind);
                                        _close();
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      PopupMenuItem(
                                        value: PhysicalKind.move,
                                        child: Text(context.tr('移动媒体')),
                                      ),
                                      PopupMenuItem(
                                        value: PhysicalKind.delete,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.delete_outline,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .error,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              context.tr('删除媒体'),
                                              style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .error,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (session.current?.kind == MediaKind.video &&
                  session.verified &&
                  !_operating)
                _videoControls(),
              if (session.current?.kind != MediaKind.video &&
                  session.errors.containsKey(session.currentKey))
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 40,
                  child: SafeArea(
                    child: Theme(
                      data: _viewerTheme,
                      child: GlassSurface(
                        dark: true,
                        highOpacity: true,
                        child: TextButton.icon(
                          onPressed: session.retry,
                          icon: const Icon(Icons.refresh),
                          label: Text(context.tr('显示图读取失败，重试')),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
  Rect _neighborRect(String key, double offset) {
    final image = session.image(key);
    final photo = widget.browser.photos.where((p) => p.key == key).firstOrNull;
    final size = image != null
        ? Size(image.width.toDouble(), image.height.toDouble())
        : Size(
            (photo?.width ?? 1).clamp(1, 100000).toDouble(),
            (photo?.height ?? 1).clamp(1, 100000).toDouble(),
          );
    return motion.fitted(size).shift(Offset(offset, 0));
  }

  Future<void> _videoOperation(Photo photo, PhysicalKind kind) async {
    if (_operating) return;
    _cancelResume();
    _operating = true;
    await playback.stop();
    if (!mounted) return;
    try {
      await widget.onPhysicalAction?.call(photo, kind);
      if (!mounted) return;
      await widget.browser.waitForRefresh();
      if (!mounted) return;
      session.settleOperation();
    } finally {
      _operating = false;
      if (mounted) _changed();
    }
  }

  Widget _videoControls() {
    final c = playback.controller;
    final duration =
        c?.value.duration.inMilliseconds ?? session.current?.durationMs ?? 0;
    final position =
        _seekPosition ?? (c?.value.position.inMilliseconds ?? 0).toDouble();
    return Positioned(
      left: 16,
      right: 16,
      bottom: 16,
      child: SafeArea(
        child: Theme(
          data: _viewerTheme,
          child: GlassSurface(
            dark: true,
            highOpacity: true,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (playback.error != null)
                    Text(context.domainText(playback.error!)),
                  if (playback.loading) const LinearProgressIndicator(),
                  Row(
                    children: [
                      IconButton(
                        tooltip: c?.value.isPlaying == true
                            ? context.tr('暂停视频')
                            : context.tr('播放视频'),
                        onPressed: playback.ready ? playback.toggle : null,
                        icon: Icon(
                          c?.value.isPlaying == true
                              ? Icons.pause
                              : Icons.play_arrow,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${mediaDuration(position.toInt())} / ${context.tr(mediaDuration(duration > 0 ? duration : null))}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: playback.muted
                            ? context.tr('开启声音')
                            : context.tr('静音'),
                        onPressed: playback.ready ? playback.toggleMute : null,
                        icon: Icon(
                          playback.muted ? Icons.volume_off : Icons.volume_up,
                        ),
                      ),
                      if (playback.error != null)
                        IconButton(
                          tooltip: context.tr('重试视频'),
                          icon: const Icon(Icons.refresh),
                          onPressed: () async {
                            await playback.stop();
                            if (mounted) _syncPlayback();
                          },
                        ),
                    ],
                  ),
                  Slider(
                    value: position.clamp(
                      0,
                      duration > 0 ? duration.toDouble() : 1,
                    ),
                    max: duration > 0 ? duration.toDouble() : 1,
                    onChangeStart: playback.ready
                        ? (_) {
                            playback.beginSeek();
                          }
                        : null,
                    onChanged: playback.ready && duration > 0
                        ? (v) => setState(() => _seekPosition = v)
                        : null,
                    onChangeEnd: playback.ready
                        ? (v) async {
                            await playback.seek(
                              Duration(milliseconds: v.round()),
                            );
                            if (mounted) setState(() => _seekPosition = null);
                          }
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _favoriteButton() {
    final favorites = widget.favorites, photo = session.current;
    if (favorites == null || photo == null) return const SizedBox(width: 48);
    if (favorites.phase == FavoritePhase.failed) {
      return IconButton(
        tooltip: context.tr('收藏读取失败，重试'),
        onPressed: favorites.load,
        icon: const Icon(Icons.error_outline, color: Colors.white),
      );
    }
    if (favorites.phase == FavoritePhase.loading) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(),
        ),
      );
    }
    final saved = favorites.contains(photo);
    final known = favorites.state(photo) != null;
    return IconButton(
      tooltip: favorites.busy(photo)
          ? context.tr('正在保存收藏')
          : favorites.failed(photo)
          ? context.tr('收藏保存失败，重试')
          : !known
          ? context.tr('系统收藏状态暂不可确认')
          : favorites.usesSystem(photo)
          ? saved
                ? context.tr('取消系统收藏')
                : context.tr('添加系统收藏')
          : saved
          ? (favorites.syncAvailable
                ? context.tr('取消应用内收藏')
                : context.tr('取消应用内收藏（系统互通未验证）'))
          : (favorites.syncAvailable
                ? context.tr('添加应用内收藏')
                : context.tr('添加应用内收藏（系统互通未验证）')),
      isSelected: saved,
      onPressed:
          session.verified &&
              favorites.phase == FavoritePhase.ready &&
              favorites.canSet(photo) &&
              !favorites.busy(photo)
          ? () async {
              await favorites.set(photo, !saved);
              final result = favorites.usesSystem(photo)
                  ? favorites.resultFor(photo)
                  : null;
              if (mounted && result != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(favoriteResultText(context, result))),
                );
              } else if (mounted && favorites.failed(photo)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.tr('收藏保存失败，请重试'))),
                );
              }
            }
          : null,
      icon: favorites.busy(photo)
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(),
            )
          : Icon(
              !known
                  ? Icons.help_outline
                  : saved
                  ? Icons.favorite
                  : Icons.favorite_border,
              color: saved
                  ? PhotoTreeStyle.darkAccent
                  : PhotoTreeStyle.darkText,
            ),
    );
  }

  Widget _frame(ui.Image? image, Rect rect, {bool isCurrent = false}) =>
      Positioned.fromRect(
        rect: rect,
        child: Opacity(
          opacity: motion.imageOpacity,
          child: ClipRect(
            child:
                isCurrent &&
                    session.current?.kind == MediaKind.video &&
                    playback.controller != null
                ? VideoPlayer(playback.controller!)
                : image == null
                ? const ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: Icon(Icons.image_outlined, color: Colors.white54),
                    ),
                  )
                : RawImage(
                    key: isCurrent
                        ? const ValueKey('viewer-current-image')
                        : null,
                    image: image,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                  ),
          ),
        ),
      );
}

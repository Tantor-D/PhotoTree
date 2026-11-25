import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'media_source.dart';

enum ThumbnailWork { visiblePreview, speculative, visibleDetail }

enum BrowsePhase { idle, checking, loading, ready, denied, failed }

// The session's only authoritative media collection and _generation owner.
class PhotoBrowser extends ChangeNotifier {
  PhotoBrowser(this.source) {
    _changes = source.changes.listen((_) {
      if (_disposed || !_foreground) return;
      suspend();
      _foreground = true;
      _changeDelay = Timer(const Duration(milliseconds: 150), () {
        if (_foreground) refresh();
      });
    });
  }
  late final StreamSubscription<void> _changes;
  Timer? _changeDelay;
  bool _foreground = true;
  bool get foreground => _foreground;
  final MediaSource source;
  int? _collectionRevision;
  int? get collectionRevision => _collectionRevision;
  String? _libraryVersion;
  String? get libraryVersion => _libraryVersion;
  PhotoAccess get access => _permissions.combined;
  MediaPermissions get permissions => _permissions;
  BrowsePhase get phase => _phase;
  MediaFailureKind? get failure => _failure;
  int get generation => _generation;
  // Image identity changes only when visible content is invalidated or replaced.
  int get imageGeneration => _imageGeneration;
  int _imageGeneration = 0;
  bool _updating = false;
  bool _checkingImages = false;
  bool get updating => _updating;
  int get maxActive => _maxActive;
  int get requested => _requested;
  int get staleResults => _staleResults;
  int get maxPixels => _maxPixels;
  List<Photo> _photos = const [];
  List<Photo> get photos => _photos;
  List<Album> get albums => albumsOf(_photos);
  MediaPermissions _permissions = const MediaPermissions.none();
  BrowsePhase _phase = BrowsePhase.idle;
  MediaFailureKind? _failure;
  int _generation = 0;
  bool _disposed = false;
  final _queue = Queue<_ThumbnailJob>();
  final _pendingThumbnails = <(int, String, int), _ThumbnailJob>{};
  bool _drainScheduled = false;
  // Preserve buffer identity so a recreated grid tile can reuse the existing
  // decoded image too. This is disposable, bounded data, never access authority.
  final _thumbnails = <(String, int), Uint8List>{};
  int _thumbnailBytes = 0;
  int _thumbnailGeneration = 0;
  int get thumbnailCacheBytes => _thumbnailBytes;
  int get thumbnailCacheEntries => _thumbnails.length;
  int _active = 0, _activeDisplay = 0;
  int _activeSpeculative = 0, _activeDetail = 0;
  int maxActiveSpeculative = 0, maxActiveDetail = 0;
  int get queuedImages => _queue.length;
  int get activeImages => _active;

  /// Decoded pixels are subject to the same authorization gate as byte reads.
  List<Photo>? _imageSnapshot;
  final _imagePhotos = <String, Photo>{};
  bool canDisplayImage(Photo photo, int imageTicket) =>
      !_disposed &&
      _foreground &&
      !_checkingImages &&
      permitted &&
      imageTicket == _imageGeneration &&
      _visibleKeys.contains(photo.key) &&
      _sameImageIdentity(photo, _imagePhotos[photo.key]);

  /// Revoke queued work immediately on a viewport change. Active source calls
  /// still own their slots until their actual futures finish.
  void reprioritizeImages() {
    for (final job in _queue.toList()) {
      if (!job.needed) {
        _queue.remove(job);
        _forgetThumbnail(job);
        job.fail(const MediaFailure(MediaFailureKind.cancelled));
      }
    }
    _scheduleDrain();
  }

  void _scheduleDrain() {
    if (_drainScheduled) return;
    _drainScheduled = true;
    scheduleMicrotask(() {
      _drainScheduled = false;
      _drain();
    });
  }

  int maxActiveDisplay = 0;
  int _maxActive = 0, _requested = 0, _staleResults = 0, _maxPixels = 0;
  final Set<String> _visibleKeys = {};
  bool get permitted => access != PhotoAccess.denied;
  bool current(int value) => !_disposed && value == _generation;

  final _refreshWaiters = <Completer<bool>>{};
  bool _settlementScheduled = false;

  /// Wait for the current refresh, including replacements and observer debounce.
  /// This does not query media or make an uncertain collection browsable.
  Future<bool> waitForRefresh() {
    final waiter = Completer<bool>();
    _refreshWaiters.add(waiter);
    _settleRefreshWaiters();
    return waiter.future;
  }

  void _settleRefreshWaiters() {
    if (_settlementScheduled || _refreshWaiters.isEmpty) return;
    _settlementScheduled = true;
    scheduleMicrotask(() {
      _settlementScheduled = false;
      // refresh briefly calls suspend synchronously before entering foreground.
      // Inspect the current state here, never a cached pre-microtask value.
      final terminal =
          _disposed ||
          !_foreground ||
          (_phase != BrowsePhase.checking && _phase != BrowsePhase.loading);
      if (!terminal) return;
      final ready =
          !_disposed &&
          _foreground &&
          _phase == BrowsePhase.ready &&
          _failure == null;
      final waiters = _refreshWaiters.toList();
      _refreshWaiters.clear();
      for (final waiter in waiters) {
        waiter.complete(ready);
      }
    });
  }

  void _publish() {
    if (!identical(_imageSnapshot, _photos)) {
      _imageSnapshot = _photos;
      _imagePhotos
        ..clear()
        ..addEntries(_photos.map((p) => MapEntry(p.key, p)));
    }
    if (_thumbnailGeneration != _imageGeneration) {
      _clearThumbnails();
      _thumbnailGeneration = _imageGeneration;
    }
    if (!_disposed) notifyListeners();
    _settleRefreshWaiters();
  }

  // Hide old content immediately, including while the app is in system settings.
  void suspend() {
    _foreground = false;
    _changeDelay?.cancel();
    _generation++;
    _imageGeneration++;
    _updating = false;
    _checkingImages = false;
    _libraryVersion = null;
    _collectionRevision = null;
    _photos = const [];
    _visibleKeys.clear();
    _phase = BrowsePhase.checking;
    while (_queue.isNotEmpty) {
      _queue.removeFirst().fail(const MediaFailure(MediaFailureKind.stale));
    }
    _publish();
  }

  Future<void> refresh({bool request = false, bool reselect = false}) =>
      _refresh(request: request, reselect: reselect, recoverRevision: true);

  Future<void> _refresh({
    bool request = false,
    bool reselect = false,
    required bool recoverRevision,
  }) async {
    // Limited access has no stable accessible-set token: always hide it until
    // the complete query confirms the newly granted set.
    final retain =
        _foreground &&
        _phase == BrowsePhase.ready &&
        access == PhotoAccess.full &&
        !request &&
        !reselect;
    final previous = _photos;
    final previousVersion = _libraryVersion;
    final previousRevision = _collectionRevision;
    if (retain) {
      _changeDelay?.cancel();
      _generation++;
      _updating = true;
      _checkingImages = true;
      _phase = BrowsePhase.loading;
      _publish();
    } else {
      suspend();
    }
    _foreground = true;
    final ticket = _generation;
    _failure = null;
    try {
      if (reselect) await source.reselect();
      final permission = await source.permission(request: request);
      if (!current(ticket)) return;
      _permissions = permission;
      if (permission.combined != PhotoAccess.full && retain) {
        _photos = const [];
        _visibleKeys.clear();
        _imageGeneration++;
        _updating = false;
        _publish();
      }
      if (!permitted) {
        _phase = BrowsePhase.denied;
        _checkingImages = false;
        _publish();
        _drain();
        return;
      }
      final version = await source.libraryVersion();
      if (!current(ticket)) return;
      if (!_updating) _libraryVersion = version;
      final revision = await source.collectionRevision();
      if (!current(ticket)) return;
      if (_updating &&
          (version == null ||
              revision == null ||
              version != previousVersion ||
              revision != previousRevision)) {
        _photos = const [];
        _visibleKeys.clear();
        _imageGeneration++;
        _updating = false;
        _libraryVersion = version;
        _collectionRevision = null;
      }
      _checkingImages = false;
      _drain();
      _phase = BrowsePhase.loading;
      _publish();
      final collected = <String, Photo>{};
      var afterId = 0;
      while (current(ticket)) {
        final batch = await source.page(afterId: afterId);
        if (!current(ticket)) return;
        for (final photo in batch) {
          if (photo.directory.isEmpty) {
            throw const MediaFailure(MediaFailureKind.attribution);
          }
          if (photo.volume != 'external_primary' || photo.id <= afterId) {
            throw const MediaFailure(MediaFailureKind.query);
          }
          if (permission.forKind(photo.kind) != PhotoAccess.denied) {
            collected[photo.key] = photo;
          }
        }
        // Pages are private to this query. Publish counts, covers and order
        // together only after the final permission and identity checks.
        if (batch.isEmpty) {
          final endVersion = await source.libraryVersion();
          final endRevision = await source.collectionRevision();
          final endAccess = await source.permission();
          if (!current(ticket)) return;
          if (endVersion != version ||
              endRevision != revision ||
              endAccess != permission) {
            // A provider transaction can advance the volume generation without
            // another media notification. Discard this read and recheck once;
            // the replacement gets no recovery budget or permission prompts.
            if (recoverRevision &&
                _foreground &&
                version != null &&
                version.isNotEmpty &&
                endVersion == version &&
                permission.combined == PhotoAccess.full &&
                endAccess == permission &&
                revision != null &&
                endRevision != null &&
                endRevision > revision) {
              await _refresh(recoverRevision: false);
              return;
            }
            throw const MediaFailure(MediaFailureKind.stale);
          }
          final next = orderedPhotos(collected.values);
          final imagesUnchanged =
              _updating &&
              previousVersion != null &&
              previousRevision != null &&
              previousVersion == version &&
              previousRevision == revision &&
              _samePhotos(previous, next, includeFavorites: false);
          if (!imagesUnchanged || !_samePhotos(previous, next)) {
            _photos = next;
            if (_updating && !imagesUnchanged) _imageGeneration++;
          }
          _libraryVersion = version;
          _visibleKeys
            ..clear()
            ..addAll(collected.keys);
          _updating = false;
          _collectionRevision = revision;
          _phase = BrowsePhase.ready;
          _publish();
          return;
        }
        final nextId = batch.map((p) => p.id).reduce((a, b) => a > b ? a : b);
        afterId = nextId;
      }
    } catch (error) {
      if (!current(ticket)) return;
      final kind = error is MediaFailure ? error.kind : MediaFailureKind.query;
      // A failed query may retain only a still-confirmed full-access snapshot.
      var keep = false;
      if (_updating &&
          previous.isNotEmpty &&
          kind == MediaFailureKind.query &&
          previousVersion != null &&
          previousRevision != null) {
        try {
          keep =
              (await source.permission()).combined == PhotoAccess.full &&
              await source.libraryVersion() == previousVersion &&
              await source.collectionRevision() == previousRevision;
        } catch (_) {
          keep = false;
        }
      }
      if (!current(ticket)) return;
      _updating = false;
      _checkingImages = false;
      if (!keep) {
        _libraryVersion = null;
        _collectionRevision = null;
        _photos = const [];
        _visibleKeys.clear();
        _imageGeneration++;
      }
      _failure = error is MediaFailure ? error.kind : MediaFailureKind.query;
      if (_failure == MediaFailureKind.permission) {
        _permissions = const MediaPermissions.none();
        _phase = BrowsePhase.denied;
      } else {
        _phase = keep ? BrowsePhase.ready : BrowsePhase.failed;
      }
      _publish();
      _drain();
    }
  }

  /// A synchronous cache hit needs no native slot. It is still gated by the
  /// current permission check, foreground session and complete media identity.
  Uint8List? cachedThumbnail(Photo photo, int pixels, int ticket) {
    if (!current(ticket) || !canDisplayImage(photo, _imageGeneration)) {
      return null;
    }
    final key = (photo.key, pixels.clamp(1, 512));
    final cached = _thumbnails.remove(key);
    if (cached != null) _thumbnails[key] = cached;
    return cached;
  }

  Future<Uint8List> thumbnail(
    Photo photo,
    int pixels,
    int ticket, {
    bool Function()? isNeeded,
    bool Function()? isPriority,
    bool reload = false,
    ThumbnailWork Function()? work,
    bool Function()? allowExtraSpeculative,
  }) {
    if (!current(ticket) || !_visibleKeys.contains(photo.key)) {
      return Future.error(const MediaFailure(MediaFailureKind.stale));
    }
    if (isNeeded?.call() == false) {
      return Future.error(const MediaFailure(MediaFailureKind.cancelled));
    }
    final size = pixels.clamp(1, 512);
    final pendingKey = (ticket, photo.key, size);
    if (reload) {
      _thumbnailBytes -=
          _thumbnails.remove((photo.key, size))?.lengthInBytes ?? 0;
      // A retry must not reuse or be overwritten by an earlier read.
      _pendingThumbnails.remove(pendingKey);
    }
    final cached = cachedThumbnail(photo, size, ticket);
    if (cached != null) return SynchronousFuture(cached);
    final pending = _pendingThumbnails[pendingKey];
    if (pending != null) {
      final request = _ImageRequest(
        isNeeded,
        isPriority,
        work,
        allowExtraSpeculative,
      );
      pending.requests.add(request);
      return request.result.future;
    }
    final job = _ThumbnailJob(
      photo,
      size,
      ticket,
      isNeeded,
      isPriority: isPriority,
      work: work,
      allowExtraSpeculative: allowExtraSpeculative,
    );
    _pendingThumbnails[pendingKey] = job;
    _queue.add(job);
    // Tiles are built in row order, including the leading offscreen cache.
    // Dispatch after this build so visibility, not build order, gets the slots.
    _scheduleDrain();
    return job.result.future;
  }

  Future<Uint8List> display(
    Photo photo,
    int pixels,
    int ticket, {
    bool Function()? isNeeded,
    bool priority = false,
  }) {
    if (!current(ticket) || !_visibleKeys.contains(photo.key)) {
      return Future.error(const MediaFailure(MediaFailureKind.stale));
    }
    final job = _ThumbnailJob(
      photo,
      pixels.clamp(1, 4096),
      ticket,
      isNeeded,
      display: true,
    );
    if (priority) {
      _queue.addFirst(job);
    } else {
      _queue.add(job);
    }
    _drain();
    return job.result.future;
  }

  void _drain() {
    if (_checkingImages) return;
    while (!_disposed && _active < 4 && _queue.isNotEmpty) {
      final eligible = _queue.where(
        (job) => job.display
            ? _activeDisplay < 2
            : switch (job.work) {
                ThumbnailWork.speculative =>
                  _activeSpeculative < 1 ||
                      (_activeSpeculative < 2 &&
                          job.extraSpeculativeAllowed &&
                          _activeDisplay == 0 &&
                          !_queue.any(
                            (other) => other.needed && other.rank < 2,
                          )),
                ThumbnailWork.visibleDetail => _activeDetail < 2,
                _ => true,
              },
      );
      if (eligible.isEmpty) break;
      // Re-evaluate at dispatch: a prefetched row may have entered the viewport
      // since it queued. Never let speculative work overtake visible images.
      final ranked = eligible.toList()
        ..sort((a, b) => a.rank.compareTo(b.rank));
      final job = ranked.first;
      _queue.remove(job);
      if (!current(job.ticket) || !_visibleKeys.contains(job.photo.key)) {
        _forgetThumbnail(job);
        job.fail(const MediaFailure(MediaFailureKind.stale));
        continue;
      }
      if (!job.needed) {
        _forgetThumbnail(job);
        job.fail(const MediaFailure(MediaFailureKind.cancelled));
        continue;
      }
      job.startedWork = job.work;
      if (job.startedWork == ThumbnailWork.speculative) {
        _activeSpeculative++;
        if (_activeSpeculative > maxActiveSpeculative) {
          maxActiveSpeculative = _activeSpeculative;
        }
      }
      if (job.startedWork == ThumbnailWork.visibleDetail) {
        _activeDetail++;
        if (_activeDetail > maxActiveDetail) maxActiveDetail = _activeDetail;
      }
      _active++;
      if (job.display) {
        _activeDisplay++;
        if (_activeDisplay > maxActiveDisplay) {
          maxActiveDisplay = _activeDisplay;
        }
      }
      if (_active > _maxActive) _maxActive = _active;
      if (!job.display && job.pixels > _maxPixels) _maxPixels = job.pixels;
      _requested++;
      _run(job);
    }
  }

  Future<void> _run(_ThumbnailJob job) async {
    try {
      final bytes = job.display
          ? await source.display(job.photo, job.pixels)
          : await source.thumbnail(job.photo, job.pixels);
      if (!current(job.ticket) || !_visibleKeys.contains(job.photo.key)) {
        _staleResults++;
        throw const MediaFailure(MediaFailureKind.stale);
      }
      if (!job.display &&
          identical(
            _pendingThumbnails[(job.ticket, job.photo.key, job.pixels)],
            job,
          ) &&
          bytes.isNotEmpty &&
          bytes.lengthInBytes <= 8 * 1024 * 1024) {
        final key = (job.photo.key, job.pixels);
        _thumbnailBytes -= _thumbnails.remove(key)?.lengthInBytes ?? 0;
        _thumbnails[key] = bytes;
        _thumbnailBytes += bytes.lengthInBytes;
        while (_thumbnails.length > 120 || _thumbnailBytes > 8 * 1024 * 1024) {
          _thumbnailBytes -= _thumbnails
              .remove(_thumbnails.keys.first)!
              .lengthInBytes;
        }
      }
      // Scrolling away cancels that caller, not valid bytes already read. A
      // returning tile may be sharing the same job or visit the bounded cache.
      for (final request in job.requests) {
        if (request.needed) {
          request.result.complete(bytes);
        } else {
          request.result.completeError(
            const MediaFailure(MediaFailureKind.cancelled),
          );
        }
      }
    } catch (error) {
      job.fail(
        error is MediaFailure
            ? error
            : const MediaFailure(MediaFailureKind.unavailable),
      );
    } finally {
      _forgetThumbnail(job);
      _active--;
      if (job.startedWork == ThumbnailWork.speculative) _activeSpeculative--;
      if (job.startedWork == ThumbnailWork.visibleDetail) _activeDetail--;
      if (job.display) _activeDisplay--;
      _drain();
    }
  }

  void _forgetThumbnail(_ThumbnailJob job) {
    final key = (job.ticket, job.photo.key, job.pixels);
    if (!job.display && identical(_pendingThumbnails[key], job)) {
      _pendingThumbnails.remove(key);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _clearThumbnails();
    _settleRefreshWaiters();
    _changeDelay?.cancel();
    _changes.cancel();
    _generation++;
    while (_queue.isNotEmpty) {
      _queue.removeFirst().fail(const MediaFailure(MediaFailureKind.cancelled));
    }
    super.dispose();
  }

  void _clearThumbnails() {
    _pendingThumbnails.clear();
    _thumbnails.clear();
    _thumbnailBytes = 0;
  }
}

class _ThumbnailJob {
  _ThumbnailJob(
    this.photo,
    this.pixels,
    this.ticket,
    bool Function()? isNeeded, {
    this.display = false,
    bool Function()? isPriority,
    ThumbnailWork Function()? work,
    bool Function()? allowExtraSpeculative,
  }) : requests = [
         _ImageRequest(isNeeded, isPriority, work, allowExtraSpeculative),
       ];
  bool get extraSpeculativeAllowed => requests.any(
    (request) =>
        request.needed && request.allowExtraSpeculative?.call() == true,
  );
  ThumbnailWork? startedWork;
  ThumbnailWork? get work {
    final kinds = requests.where((r) => r.needed).map((r) => r.work?.call());
    if (kinds.contains(ThumbnailWork.visiblePreview)) {
      return ThumbnailWork.visiblePreview;
    }
    if (kinds.contains(ThumbnailWork.visibleDetail)) {
      return ThumbnailWork.visibleDetail;
    }
    if (kinds.contains(ThumbnailWork.speculative)) {
      return ThumbnailWork.speculative;
    }
    return null;
  }

  int get rank => display || work == ThumbnailWork.visiblePreview
      ? 0
      : work == ThumbnailWork.visibleDetail || priority
      ? 1
      : 2;
  final bool display;
  final List<_ImageRequest> requests;
  bool get needed => requests.any((request) => request.needed);
  bool get priority => requests.any(
    (request) => request.needed && request.isPriority?.call() == true,
  );
  Completer<Uint8List> get result => requests.first.result;
  void fail(MediaFailure error) {
    for (final request in requests) {
      request.result.completeError(error);
    }
  }

  final Photo photo;
  final int pixels, ticket;
}

class _ImageRequest {
  _ImageRequest(
    this.isNeeded,
    this.isPriority,
    this.work,
    this.allowExtraSpeculative,
  );
  final bool Function()? allowExtraSpeculative;
  final ThumbnailWork Function()? work;
  final bool Function()? isNeeded;
  final bool Function()? isPriority;
  bool get needed => isNeeded?.call() != false;
  final result = Completer<Uint8List>();
}

// Compare actual metadata as well as the platform revision; test sources and
// providers may omit revision support or reuse values.
bool _samePhotos(List<Photo> a, List<Photo> b, {bool includeFavorites = true}) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i], y = b[i];
    if (x.key != y.key ||
        x.directory != y.directory ||
        x.takenMs != y.takenMs ||
        x.addedSeconds != y.addedSeconds ||
        x.width != y.width ||
        x.height != y.height ||
        x.durationMs != y.durationMs ||
        (includeFavorites && x.systemFavorite != y.systemFavorite)) {
      return false;
    }
  }
  return true;
}

bool _sameImageIdentity(Photo a, Photo? b) =>
    b != null &&
    a.key == b.key &&
    a.directory == b.directory &&
    a.takenMs == b.takenMs &&
    a.addedSeconds == b.addedSeconds &&
    a.width == b.width &&
    a.height == b.height &&
    a.durationMs == b.durationMs;

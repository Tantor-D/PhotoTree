import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import 'media_source.dart';

class AndroidMediaSource implements MediaSource {
  AndroidMediaSource() {
    _changes = StreamController<void>.broadcast(
      onListen: () {
        PhotoManager.addChangeCallback(_onChange);
        unawaited(PhotoManager.startChangeNotify());
      },
      onCancel: () {
        PhotoManager.removeChangeCallback(_onChange);
        unawaited(PhotoManager.stopChangeNotify());
      },
    );
  }
  late final StreamController<void> _changes;
  void _onChange(MethodCall _) => _changes.add(null);
  @override
  Stream<void> get changes => _changes.stream;

  static const _metadata = MethodChannel('io.github.tantor_d.phototree/metadata');
  static const _options = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.common,
      mediaLocation: false,
    ),
  );
  @override
  Future<MediaPermissions> permission({bool request = false}) async {
    if (request) {
      await PhotoManager.requestPermissionExtend(requestOption: _options);
    }
    Future<PhotoAccess> state(RequestType type) async {
      final value = await PhotoManager.getPermissionState(
        requestOption: PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: type,
            mediaLocation: false,
          ),
        ),
      );
      return value == PermissionState.authorized
          ? PhotoAccess.full
          : value == PermissionState.limited
          ? PhotoAccess.limited
          : PhotoAccess.denied;
    }

    return MediaPermissions(
      images: await state(RequestType.image),
      videos: await state(RequestType.video),
    );
  }

  @override
  Future<void> reselect() =>
      PhotoManager.presentLimited(type: RequestType.common);
  @override
  Future<void> openSettings() => PhotoManager.openSetting();
  @override
  Future<Uri> playbackUri(Photo photo, String libraryVersion) async {
    if (photo.kind != MediaKind.video) {
      throw const MediaFailure(MediaFailureKind.unavailable);
    }
    final value = await _metadata.invokeMethod<String>('playbackUri', {
      'id': photo.id,
      'volume': photo.volume,
      'mediaKind': photo.kind.name,
      'libraryVersion': libraryVersion,
      'directory': photo.directory,
      'addedSeconds': photo.addedSeconds,
      'takenMs': photo.takenMs,
      'width': photo.width,
      'height': photo.height,
    });
    final uri = value == null ? null : Uri.tryParse(value);
    if (uri == null || uri.scheme != 'content' || uri.authority != 'media') {
      throw const MediaFailure(MediaFailureKind.unavailable);
    }
    return uri;
  }

  @override
  Future<String?> libraryVersion() async {
    try {
      return await _metadata.invokeMethod<String>('version');
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<int?> collectionRevision() async {
    try {
      return await _metadata.invokeMethod<int>('collectionRevision');
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<List<Photo>> page({required int afterId}) async {
    try {
      final rows = await _metadata.invokeListMethod<Object?>('page', {
        'afterId': afterId,
      });
      if (rows == null) throw const MediaFailure(MediaFailureKind.query);
      return rows.map((row) {
        final value = Map<String, dynamic>.from(row! as Map);
        return Photo(
          id: value['id'] as int,
          directory: value['directory'] as String,
          volume: value['volume'] as String,
          takenMs: value['takenMs'] as int,
          addedSeconds: value['addedSeconds'] as int,
          width: value['width'] as int,
          height: value['height'] as int,
          systemFavorite: value['systemFavorite'] as bool?,
          kind: mediaKindFrom(value['mediaKind']),
          durationMs: value['durationMs'] as int?,
        );
      }).toList();
    } on PlatformException catch (error) {
      throw MediaFailure(
        error.code == 'permission'
            ? MediaFailureKind.permission
            : error.code == 'directory'
            ? MediaFailureKind.attribution
            : MediaFailureKind.query,
      );
    }
  }

  @override
  Future<Uint8List> thumbnail(Photo photo, int pixels) =>
      _image(photo, pixels.clamp(1, 512), false);

  @override
  Future<Uint8List> display(Photo photo, int pixels) =>
      _image(photo, pixels.clamp(1, 4096), true);

  Future<Uint8List> _image(Photo photo, int pixels, bool display) async {
    // Fetching properties checks access again; cached entities cannot authorize an ID.
    final entity = await AssetEntity.fromId(photo.id.toString());
    if (entity == null ||
        (photo.kind == MediaKind.image
            ? entity.type != AssetType.image
            : entity.type != AssetType.video)) {
      throw const MediaFailure(MediaFailureKind.unavailable);
    }
    final width = entity.orientatedWidth;
    final height = entity.orientatedHeight;
    if (width <= 0 || height <= 0) {
      throw const MediaFailure(MediaFailureKind.unavailable);
    }
    // Glide fills the requested box: a square request can produce a 683px edge.
    // Match the oriented aspect ratio so the longest requested edge stays bounded.
    final scale = math.min(1.0, pixels / math.max(width, height));
    final size = ThumbnailSize(
      math.max(1, (width * scale).floor()),
      math.max(1, (height * scale).floor()),
    );
    final bytes = await entity.thumbnailDataWithSize(
      size,
      quality: 85,
      format: display ? ThumbnailFormat.png : ThumbnailFormat.jpeg,
    );
    if (bytes == null || bytes.isEmpty) {
      throw const MediaFailure(MediaFailureKind.unavailable);
    }
    return bytes;
  }
}

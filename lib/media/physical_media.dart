import 'package:flutter/services.dart';

import 'media_source.dart';

enum PhysicalKind { move, delete }

enum PhysicalOutcome {
  confirmed,
  unchanged,
  cancelled,
  permission,
  stale,
  unsupported,
  failed,
  unknown,
  busy,
}

class PhysicalPhotoSnapshot {
  const PhysicalPhotoSnapshot({
    required this.photo,
    required this.libraryVersion,
    required this.displayName,
    required this.size,
    required this.mimeType,
    required this.modifiedSeconds,
    required this.generationModified,
    required this.sha256,
  });
  final Photo photo;
  final String libraryVersion, displayName, mimeType, sha256;
  final int size, modifiedSeconds, generationModified;
  Map<String, Object?> toMap() => {
    ..._photoMap(photo),
    'libraryVersion': libraryVersion,
    'displayName': displayName,
    'size': size,
    'mimeType': mimeType,
    'modifiedSeconds': modifiedSeconds,
    'generationModified': generationModified,
    'sha256': sha256,
  };
  factory PhysicalPhotoSnapshot.fromMap(Map map) => PhysicalPhotoSnapshot(
    photo: Photo(
      id: map['id'] as int,
      directory: map['directory'] as String,
      volume: map['volume'] as String,
      takenMs: map['takenMs'] as int,
      addedSeconds: map['addedSeconds'] as int,
      width: map['width'] as int,
      height: map['height'] as int,
      kind: mediaKindFrom(map['mediaKind']),
      durationMs: map['durationMs'] as int?,
    ),
    libraryVersion: map['libraryVersion'] as String,
    displayName: map['displayName'] as String,
    size: map['size'] as int,
    mimeType: map['mimeType'] as String,
    modifiedSeconds: map['modifiedSeconds'] as int,
    generationModified: map['generationModified'] as int,
    sha256: map['sha256'] as String,
  );
}

Map<String, Object?> _photoMap(Photo photo) => {
  'id': photo.id,
  'volume': photo.volume,
  'directory': photo.directory,
  'takenMs': photo.takenMs,
  'addedSeconds': photo.addedSeconds,
  'width': photo.width,
  'height': photo.height,
  if (photo.kind != MediaKind.image) 'mediaKind': photo.kind.name,
  if (photo.durationMs != null) 'durationMs': photo.durationMs,
};

class PhysicalPreparation {
  const PhysicalPreparation(
    this.outcome, {
    this.photos = const [],
    this.reason,
  });
  final String? reason;
  final PhysicalOutcome outcome;
  final List<PhysicalPhotoSnapshot> photos;
}

class PhysicalAlbumInspection {
  const PhysicalAlbumInspection(
    this.outcome, {
    this.photos = const [],
    this.empty = false,
    this.reason,
    this.directoryToken,
  });
  final PhysicalOutcome outcome;
  final List<PhysicalPhotoSnapshot> photos;
  final bool empty;
  final String? directoryToken;
  final String? reason;
}

class PhysicalResult {
  const PhysicalResult(this.outcome, {this.after, this.reason});
  final String? reason;
  final PhysicalOutcome outcome;
  final PhysicalPhotoSnapshot? after;
}

abstract interface class PhysicalMediaAccess {
  /// Read-validates this exact group, then requests only missing write grants.
  /// Does not mutate media. A grant is never a durable permission cache.
  Future<PhysicalResult> authorizePhotos(List<PhysicalPhotoSnapshot> photos);

  /// Busy/unknown keeps recovery blocked while an external request may exist.
  Future<PhysicalOutcome> authorizationState();
  Future<PhysicalPreparation> prepare(
    List<Photo> photos,
    String libraryVersion, {
    String? targetDirectory,
  });
  Future<PhysicalAlbumInspection> inspectAlbum(String volume, String path);
  Future<PhysicalResult> executePhoto(
    PhysicalKind kind,
    PhysicalPhotoSnapshot snapshot, {
    String? targetDirectory,
    bool authorized = false,
  });
  Future<PhysicalResult> reconcilePhoto(
    PhysicalKind kind,
    PhysicalPhotoSnapshot snapshot, {
    String? targetDirectory,
  });
  Future<PhysicalResult> deleteEmptyAlbum(
    String volume,
    String path, {
    required String directoryToken,
  });
  Future<PhysicalResult> reconcileEmptyAlbum(
    String volume,
    String path, {
    required String directoryToken,
  });
}

class AndroidPhysicalMediaAccess implements PhysicalMediaAccess {
  static const _channel = MethodChannel('io.github.tantor_d.phototree/physicalMedia');
  @override
  Future<PhysicalResult> authorizePhotos(
    List<PhysicalPhotoSnapshot> photos,
  ) async {
    final reply = await _call('authorizePhotos', {
      'photos': photos.map((p) => p.toMap()).toList(),
    });
    return PhysicalResult(_outcome(reply), reason: reply['reason'] as String?);
  }

  @override
  Future<PhysicalOutcome> authorizationState() async =>
      _outcome(await _call('authorizationState', {}));
  Future<Map> _call(String method, Map<String, Object?> args) async {
    try {
      final reply = await _channel.invokeMethod<Object?>(method, args);
      return reply is Map ? reply : {'outcome': 'unknown'};
    } on MissingPluginException {
      return {'outcome': 'unsupported'};
    } on PlatformException {
      return {'outcome': 'unknown'};
    }
  }

  PhysicalOutcome _outcome(Map reply) =>
      PhysicalOutcome.values
          .where((v) => v.name == reply['outcome'])
          .firstOrNull ??
      PhysicalOutcome.unknown;
  List<PhysicalPhotoSnapshot> _photos(Map reply) => List.unmodifiable(
    (reply['photos'] as List? ?? []).map(
      (v) => PhysicalPhotoSnapshot.fromMap(v as Map),
    ),
  );
  @override
  Future<PhysicalPreparation> prepare(
    List<Photo> photos,
    String libraryVersion, {
    String? targetDirectory,
  }) async {
    final reply = await _call('prepare', {
      'photos': photos.map(_photoMap).toList(),
      'libraryVersion': libraryVersion,
      'targetDirectory': targetDirectory,
    });
    try {
      return PhysicalPreparation(
        _outcome(reply),
        photos: _photos(reply),
        reason: reply['reason'] as String?,
      );
    } catch (_) {
      return const PhysicalPreparation(PhysicalOutcome.unknown);
    }
  }

  @override
  Future<PhysicalAlbumInspection> inspectAlbum(
    String volume,
    String path,
  ) async {
    final reply = await _call('inspectAlbum', {'volume': volume, 'path': path});
    try {
      return PhysicalAlbumInspection(
        _outcome(reply),
        photos: _photos(reply),
        empty: reply['empty'] == true,
        directoryToken: reply['directoryToken'] as String?,
        reason: reply['reason'] as String?,
      );
    } catch (_) {
      return const PhysicalAlbumInspection(PhysicalOutcome.unknown);
    }
  }

  Future<PhysicalResult> _photo(
    String method,
    PhysicalKind kind,
    PhysicalPhotoSnapshot snapshot,
    String? target, {
    bool authorized = false,
  }) async {
    final reply = await _call(method, {
      'kind': kind.name,
      'snapshot': snapshot.toMap(),
      'targetDirectory': target,
      'authorized': authorized,
    });
    try {
      return PhysicalResult(
        _outcome(reply),
        reason: reply['reason'] as String?,
        after: reply['after'] is Map
            ? PhysicalPhotoSnapshot.fromMap(reply['after'] as Map)
            : null,
      );
    } catch (_) {
      return const PhysicalResult(PhysicalOutcome.unknown);
    }
  }

  @override
  Future<PhysicalResult> executePhoto(
    PhysicalKind kind,
    PhysicalPhotoSnapshot snapshot, {
    String? targetDirectory,
    bool authorized = false,
  }) => _photo(
    'executePhoto',
    kind,
    snapshot,
    targetDirectory,
    authorized: authorized,
  );
  @override
  Future<PhysicalResult> reconcilePhoto(
    PhysicalKind kind,
    PhysicalPhotoSnapshot snapshot, {
    String? targetDirectory,
  }) => _photo('reconcilePhoto', kind, snapshot, targetDirectory);
  @override
  Future<PhysicalResult> reconcileEmptyAlbum(
    String volume,
    String path, {
    required String directoryToken,
  }) async => PhysicalResult(
    _outcome(
      await _call('reconcileEmptyAlbum', {
        'volume': volume,
        'path': path,
        'directoryToken': directoryToken,
      }),
    ),
  );
  @override
  Future<PhysicalResult> deleteEmptyAlbum(
    String volume,
    String path, {
    required String directoryToken,
  }) async => PhysicalResult(
    _outcome(
      await _call('deleteEmptyAlbum', {
        'volume': volume,
        'path': path,
        'directoryToken': directoryToken,
      }),
    ),
  );
}

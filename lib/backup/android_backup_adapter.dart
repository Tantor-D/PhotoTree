import 'package:flutter/services.dart';

import '../media/media_source.dart';
import 'backup_codec.dart';
import 'backup_export.dart';
import 'backup_restore.dart';

class AndroidBackupAdapter
    implements OriginalReader, BackupOutput, BackupInput, RestoreMedia {
  static const _channel = MethodChannel('io.github.tantor_d.phototree/backup');
  @override
  Future<bool> permission({bool request = false}) async =>
      await _channel.invokeMethod<bool>(
        request ? 'requestOriginalPermission' : 'originalPermission',
      ) ??
      false;
  @override
  Future<OriginalFingerprint> read(Photo photo, String libraryVersion) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'fingerprint',
      {
        'id': photo.id,
        if (photo.kind != MediaKind.image) 'mediaKind': photo.kind.name,
        'volume': photo.volume,
        'version': libraryVersion,
        'directory': photo.directory,
        'addedSeconds': photo.addedSeconds,
        'takenMs': photo.takenMs,
        'width': photo.width,
        'height': photo.height,
      },
    );
    if (result == null) throw StateError('No original fingerprint');
    return OriginalFingerprint(
      BackupFingerprint(
        size: result['size'] as int,
        sha256: result['sha256'] as String,
      ),
      result['filename'] as String?,
    );
  }

  @override
  Future<void> cancel() => _channel.invokeMethod<void>('cancelRead');
  @override
  Future<Uint8List?> open() async {
    try {
      return await _channel.invokeMethod<Uint8List>('open');
    } on PlatformException catch (error) {
      throw BackupInputFailure(
        error.code == 'input_too_large'
            ? BackupInputFailureKind.tooLarge
            : BackupInputFailureKind.unavailable,
      );
    }
  }

  @override
  Future<int> size(Photo photo, String version) async {
    final size = await _channel.invokeMethod<int>('size', {
      'id': photo.id,
      if (photo.kind != MediaKind.image) 'mediaKind': photo.kind.name,
      'volume': photo.volume,
      'version': version,
      'directory': photo.directory,
      'addedSeconds': photo.addedSeconds,
      'takenMs': photo.takenMs,
      'width': photo.width,
      'height': photo.height,
    });
    if (size == null || size < 0) throw StateError('Media size unavailable');
    return size;
  }

  @override
  Future<String?> filename(Photo photo, String version) =>
      _channel.invokeMethod<String>('filename', {
        'id': photo.id,
        if (photo.kind != MediaKind.image) 'mediaKind': photo.kind.name,
        'volume': photo.volume,
        'version': version,
        'directory': photo.directory,
        'addedSeconds': photo.addedSeconds,
        'takenMs': photo.takenMs,
        'width': photo.width,
        'height': photo.height,
      });

  @override
  Future<bool> save(Uint8List bytes) async =>
      await _channel.invokeMethod<bool>('save', {'bytes': bytes}) ?? false;
}

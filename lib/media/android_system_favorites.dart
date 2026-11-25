import 'dart:async';

import 'package:flutter/services.dart';

import 'media_source.dart';
import 'system_favorites.dart';

class AndroidSystemFavorites implements SystemFavoriteAccess {
  AndroidSystemFavorites({this.requestsSupported = false});
  @override
  final bool requestsSupported;
  static const _channel = MethodChannel('io.github.tantor_d.phototree/systemFavorites');
  bool _busy = false;

  @override
  Future<bool?> hasPendingRequest() async {
    if (!requestsSupported) return false;
    try {
      final reply = await _channel
          .invokeMethod<Object?>('pending')
          .timeout(const Duration(seconds: 3));
      return reply is bool ? reply : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  @override
  Future<SystemFavoriteResult> set(
    Photo photo,
    String libraryVersion,
    bool value,
  ) async {
    if (!requestsSupported) {
      return const SystemFavoriteResult(SystemFavoriteOutcome.unsupported);
    }
    if (_busy) return const SystemFavoriteResult(SystemFavoriteOutcome.busy);
    if (libraryVersion.isEmpty || photo.id <= 0) {
      return const SystemFavoriteResult(SystemFavoriteOutcome.stale);
    }
    _busy = true;
    try {
      final result = await _channel.invokeMethod<Object?>('set', {
        'id': photo.id,
        if (photo.kind != MediaKind.image) 'mediaKind': photo.kind.name,
        'volume': photo.volume,
        'libraryVersion': libraryVersion,
        'takenMs': photo.takenMs,
        'addedSeconds': photo.addedSeconds,
        'width': photo.width,
        'height': photo.height,
        'value': value,
      });
      // Decode the untrusted platform reply only after checking its shape.
      // A malformed response cannot prove whether the external write happened.
      if (result is! Map) {
        return const SystemFavoriteResult(
          SystemFavoriteOutcome.unknown,
          pending: null,
        );
      }
      final outcome = SystemFavoriteOutcome.values
          .where((candidate) => candidate.name == result['outcome'])
          .firstOrNull;
      final current = result['value'];
      final pending = result.containsKey('pending') ? result['pending'] : false;
      if (pending is! bool ||
          (pending && outcome != SystemFavoriteOutcome.unknown) ||
          outcome == null ||
          (current != null && current is! bool) ||
          (outcome == SystemFavoriteOutcome.confirmed && current != value)) {
        return const SystemFavoriteResult(
          SystemFavoriteOutcome.unknown,
          pending: null,
        );
      }
      return SystemFavoriteResult(
        outcome,
        value: current as bool?,
        pending: pending,
        changed: result['changed'] == true,
      );
    } on MissingPluginException {
      return const SystemFavoriteResult(SystemFavoriteOutcome.unsupported);
    } on PlatformException {
      // A channel error does not prove that a system request was never applied.
      return const SystemFavoriteResult(
        SystemFavoriteOutcome.unknown,
        pending: null,
      );
    } finally {
      _busy = false;
    }
  }
}

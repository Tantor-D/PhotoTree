import 'media_source.dart';

enum SystemFavoriteOutcome {
  confirmed,
  cancelled,
  unsupported,
  permission,
  stale,
  failed,
  unknown,
  busy,
}

class SystemFavoriteResult {
  const SystemFavoriteResult(
    this.outcome, {
    this.value,
    this.pending = false,
    this.changed = false,
  });
  final SystemFavoriteOutcome outcome;
  final bool? value;
  final bool changed;
  // Null means the reply could not establish whether native work remains live.
  final bool? pending;
}

// A confirmed result describes the freshly read state, not an enduring promise
// that another app cannot change it. An unknown result must never be replayed.
abstract interface class SystemFavoriteAccess {
  bool get requestsSupported;
  // Read-only process state; false is the only result that proves no live request.
  Future<bool?> hasPendingRequest();
  Future<SystemFavoriteResult> set(
    Photo photo,
    String libraryVersion,
    bool value,
  );
}

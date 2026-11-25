/// A real local directory, not an organization-tree folder or backup URI.
class DirectoryIdentity {
  const DirectoryIdentity(this.volume, this.path);
  final String volume;
  final String path;
  String get key => '$volume:$path';
  bool get supported {
    if (volume != 'external_primary' || !path.endsWith('/')) return false;
    final parts = path.substring(0, path.length - 1).split('/');
    return parts.isNotEmpty &&
        (parts.first == 'Pictures' || parts.first == 'DCIM') &&
        parts.every(
          (p) =>
              p.isNotEmpty &&
              p != '.' &&
              p != '..' &&
              !p.contains('\\') &&
              !p.contains('\u0000'),
        );
  }
}

enum DirectoryStatus {
  available,
  needsAuthorization,
  revoked,
  unavailable,
  unsupported,
}

enum SafePrimitive { unknown, unsupported, verified }

enum DirectoryRequest { granted, cancelled, rejected, busy, interrupted }

class DirectoryCapabilities {
  const DirectoryCapabilities({
    required this.status,
    required this.reason,
    this.readable = false,
    this.listable = false,
    this.create = SafePrimitive.unknown,
    this.move = SafePrimitive.unknown,
    this.deleteEmpty = SafePrimitive.unknown,
  });
  final DirectoryStatus status;
  final String reason;
  final bool readable, listable;
  final SafePrimitive create, move, deleteEmpty;
}

/// Every check consults current storage and grants. A result is diagnostic, never
/// a reusable write authorization. Handles and URI parsing stay in the adapter.
abstract interface class DirectoryAccess {
  Future<DirectoryCapabilities> inspect(DirectoryIdentity directory);
  Future<DirectoryRequest> authorize(DirectoryIdentity directory);
}

enum DirectoryContents { empty, content, needsAuthorization, missing, failed }

class DirectoryReading {
  const DirectoryReading(this.contents, this.reason);
  final DirectoryContents contents;
  final String reason;
  bool get verified =>
      contents == DirectoryContents.empty ||
      contents == DirectoryContents.content;
}

enum DirectoryCreationResult { created, conflict, failed, unknown }

/// Tokens identify one live adapter session. They are never persisted/exported.
abstract interface class PhysicalDirectoryAccess implements DirectoryAccess {
  Future<DirectoryReading> readDirectory(DirectoryIdentity directory);
  Future<String?> begin(DirectoryIdentity directory);
  Future<DirectoryCreationResult> create(String token, String name);
  Future<bool> verify(String token);
  Future<void> end(String token);
}

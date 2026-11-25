import 'organization.dart';
import '../storage/directory_access.dart';

enum CreationOutcome {
  prepared,
  created,
  unknown,
  completed,
  conflict,
  failed,
  cancelled,
}

enum CreationResolution { none, associated, dismissed }

class AlbumCreationRecord {
  const AlbumCreationRecord({
    required this.id,
    required this.parentDirectory,
    required this.name,
    required this.treeParent,
    required this.outcome,
    this.resolution = CreationResolution.none,
    this.associatedKey,
  });
  final String id, parentDirectory, name, treeParent;
  final CreationOutcome outcome;
  final CreationResolution resolution;
  final String? associatedKey;
  String get directory => '$parentDirectory$name/';
  String get key => 'external_primary:$directory';
  bool get unresolved =>
      resolution == CreationResolution.none &&
      [
        CreationOutcome.prepared,
        CreationOutcome.created,
        CreationOutcome.unknown,
      ].contains(outcome);
  AlbumCreationRecord update({
    CreationOutcome? outcome,
    CreationResolution? resolution,
    String? associatedKey,
  }) => AlbumCreationRecord(
    id: id,
    parentDirectory: parentDirectory,
    name: name,
    treeParent: treeParent,
    outcome: outcome ?? this.outcome,
    resolution: resolution ?? this.resolution,
    associatedKey: associatedKey ?? this.associatedKey,
  );
  Map<String, Object?> toData() => {
    'id': id,
    'parentDirectory': parentDirectory,
    'name': name,
    'treeParent': treeParent,
    'outcome': outcome.name,
    'resolution': resolution.name,
    'associatedKey': associatedKey,
  };
  factory AlbumCreationRecord.fromData(Map<String, dynamic> m) {
    final r = AlbumCreationRecord(
      id: m['id'] as String,
      parentDirectory: m['parentDirectory'] as String,
      name: m['name'] as String,
      treeParent: m['treeParent'] as String,
      outcome: CreationOutcome.values.byName(m['outcome'] as String),
      resolution: CreationResolution.values.byName(m['resolution'] as String),
      associatedKey: m['associatedKey'] as String?,
    );
    if (r.id.isEmpty ||
        r.treeParent.isEmpty ||
        !DirectoryIdentity('external_primary', r.parentDirectory).supported ||
        physicalAlbumName(r.name) != r.name ||
        (r.resolution == CreationResolution.associated &&
            (r.associatedKey == null ||
                !r.associatedKey!.startsWith('external_primary:') ||
                !DirectoryIdentity(
                  'external_primary',
                  r.associatedKey!.substring('external_primary:'.length),
                ).supported)) ||
        (r.resolution != CreationResolution.none &&
            r.outcome != CreationOutcome.unknown) ||
        (r.resolution != CreationResolution.associated &&
            r.associatedKey != null)) {
      throw const FormatException('Invalid creation journal');
    }
    return r;
  }
}

String physicalAlbumName(String input) {
  final name = folderName(input);
  if (name.startsWith('.') || name.contains('/') || name.contains('\\')) {
    throw const OrganizationError('相册名称不能以点开头或包含路径分隔符');
  }
  return name;
}

/// Implemented by the existing organization database, keeping the journal out
/// of snapshots/backups. Final tree + history disposition share one transaction.
abstract interface class AlbumCreationStore {
  Future<List<AlbumCreationRecord>> readCreations();
  Future<void> recordCreation(AlbumCreationRecord record);
  Future<void> commitCreation(
    OrganizationSnapshot before,
    OrganizationSnapshot after,
    AlbumCreationRecord record, {
    Future<bool> Function()? validate,
  });
}

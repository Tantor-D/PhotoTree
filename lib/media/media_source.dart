import 'dart:typed_data';

enum PhotoAccess { denied, limited, full }

enum MediaKind { image, video }

class MediaPermissions {
  const MediaPermissions({required this.images, required this.videos});
  const MediaPermissions.none()
    : images = PhotoAccess.denied,
      videos = PhotoAccess.denied;
  final PhotoAccess images, videos;
  PhotoAccess forKind(MediaKind kind) =>
      kind == MediaKind.image ? images : videos;
  PhotoAccess get combined =>
      images == PhotoAccess.full && videos == PhotoAccess.full
      ? PhotoAccess.full
      : images == PhotoAccess.denied && videos == PhotoAccess.denied
      ? PhotoAccess.denied
      : PhotoAccess.limited;
  String get description {
    String label(PhotoAccess value) => switch (value) {
      PhotoAccess.full => '全量',
      PhotoAccess.limited => '所选项',
      PhotoAccess.denied => '未授权',
    };
    return '图片：${label(images)} · 视频：${label(videos)}';
  }

  @override
  bool operator ==(Object other) =>
      other is MediaPermissions &&
      images == other.images &&
      videos == other.videos;
  @override
  int get hashCode => Object.hash(images, videos);
}

// Missing type is reserved for persisted records written before video support.
// Unknown explicit values must never fall through to an image operation.
MediaKind mediaKindFrom(Object? value) => switch (value) {
  null || 'image' => MediaKind.image,
  'video' => MediaKind.video,
  _ => throw const FormatException('Unknown media kind'),
};

enum MediaFailureKind {
  permission,
  query,
  attribution,
  unavailable,
  cancelled,
  stale,
}

class MediaFailure implements Exception {
  const MediaFailure(this.kind);
  final MediaFailureKind kind;
}

class Photo {
  const Photo({
    required this.id,
    required this.directory,
    this.volume = 'external_primary',
    this.takenMs = 0,
    this.addedSeconds = 0,
    this.width = 0,
    this.height = 0,
    this.systemFavorite,
    this.kind = MediaKind.image,
    this.durationMs,
  });
  final MediaKind kind;
  final int? durationMs;
  final bool? systemFavorite;
  final int id;
  final String volume;
  final String directory;
  final int takenMs, addedSeconds, width, height;
  String get key =>
      kind == MediaKind.image ? '$volume:$id' : '$volume:video:$id';
  String get albumKey => '$volume:$directory';
  int get timeMs =>
      takenMs > 0 ? takenMs : (addedSeconds > 0 ? addedSeconds * 1000 : 0);
}

// Implementations translate platform failures. No plugin objects cross this seam.
abstract interface class MediaSource {
  Stream<void> get changes;
  Future<MediaPermissions> permission({bool request = false});
  Future<void> reselect();
  Future<void> openSettings();
  Future<String?> libraryVersion();
  // Collection changes are independent of stable favorite library identity.
  Future<int?> collectionRevision();
  Future<List<Photo>> page({required int afterId});
  Future<Uint8List> thumbnail(Photo photo, int pixels);
  Future<Uint8List> display(Photo photo, int pixels);
  Future<Uri> playbackUri(Photo photo, String libraryVersion);
}

List<Photo> orderedPhotos(Iterable<Photo> photos) {
  final result = photos.toList()
    ..sort((a, b) {
      final time = b.timeMs.compareTo(a.timeMs);
      if (time != 0) return time;
      final id = b.id.compareTo(a.id);
      return id != 0 ? id : a.key.compareTo(b.key);
    });
  return List.unmodifiable(result);
}

enum AlbumAvailability { indexed, empty, unindexed, unverified, missing }

class Album {
  Album(
    this.key,
    this.directory,
    Iterable<Photo> items, {
    this.availability = AlbumAvailability.indexed,
    this.status,
  }) : photos = List.unmodifiable(items);
  final String key, directory;
  final List<Photo> photos;
  final AlbumAvailability availability;
  final String? status;
  String get name {
    final parts = directory.split('/').where((part) => part.isNotEmpty);
    return parts.isEmpty ? '共享存储根目录' : parts.last;
  }
}

List<Album> albumsOf(List<Photo> photos) {
  final grouped = <String, List<Photo>>{};
  for (final photo in photos) {
    (grouped[photo.albumKey] ??= []).add(photo);
  }
  return List.unmodifiable(
    grouped.entries
        .map(
          (entry) => Album(entry.key, entry.value.first.directory, entry.value),
        )
        .toList()
      ..sort((a, b) {
        final name = a.name.compareTo(b.name);
        return name != 0 ? name : a.key.compareTo(b.key);
      }),
  );
}

String photoDay(Photo photo) {
  if (photo.timeMs <= 0) return '日期未知';
  final date = DateTime.fromMillisecondsSinceEpoch(photo.timeMs);
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

String mediaSelectionSummary(Iterable<Photo> photos) {
  var images = 0, videos = 0;
  for (final photo in photos) {
    photo.kind == MediaKind.image ? images++ : videos++;
  }
  return '图片 $images、视频 $videos';
}

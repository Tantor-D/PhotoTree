import '../media/media_source.dart';
import 'favorites.dart';

enum LibraryView { all, favorite, recent, images, videos }

bool inRecent(int addedMs, int nowMs) =>
    addedMs > 0 &&
    addedMs >= nowMs - const Duration(days: 30).inMilliseconds &&
    addedMs <= nowMs;

List<Photo> viewPhotos(
  List<Photo> photos,
  LibraryView view,
  Favorites? favorites,
  DateTime now,
) {
  switch (view) {
    case LibraryView.favorite:
      return List.unmodifiable(
        photos.where((p) => favorites?.contains(p) == true),
      );
    case LibraryView.recent:
      return List.unmodifiable(
        photos
            .where(
              (p) =>
                  inRecent(p.addedSeconds * 1000, now.millisecondsSinceEpoch),
            )
            .toList()
          ..sort((a, b) {
            final time = b.addedSeconds.compareTo(a.addedSeconds);
            if (time != 0) return time;
            final id = b.id.compareTo(a.id);
            return id != 0 ? id : a.key.compareTo(b.key);
          }),
      );
    case LibraryView.images:
      return List.unmodifiable(photos.where((p) => p.kind == MediaKind.image));
    case LibraryView.videos:
      return List.unmodifiable(photos.where((p) => p.kind == MediaKind.video));
    case LibraryView.all:
      return photos;
  }
}

String viewDay(Photo photo, LibraryView view) => view == LibraryView.recent
    ? photoDay(
        Photo(
          id: photo.id,
          directory: photo.directory,
          addedSeconds: photo.addedSeconds,
        ),
      )
    : photoDay(photo);

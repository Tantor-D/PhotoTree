import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/library/favorites.dart';
import 'package:phototree/library/views.dart';
import 'package:phototree/media/browser.dart';

import 'media_browser_test.dart' show FakeMedia, photo;

class MemoryFavorites implements FavoriteStore {
  final records = <String>{};
  List<PendingFavorite> unresolved = [];
  Map<String, String> migrationOutcomes = {};
  Map<String, String> sources = {};
  @override
  Future<FavoriteSnapshot> readSnapshot() async =>
      FavoriteSnapshot(await read(), unresolved, migrationOutcomes, sources);
  @override
  Future<void> replace(FavoriteSnapshot snapshot) async {
    if (failWrite) throw StateError('write');
    records
      ..clear()
      ..addAll(snapshot.confirmed);
    unresolved = snapshot.pending;
    migrationOutcomes = Map.of(snapshot.migrationOutcomes);
    sources = Map.of(snapshot.sources);
  }

  bool failRead = false, failWrite = false;
  Completer<void>? pending;
  int writes = 0;
  @override
  Future<Set<String>> read() async {
    if (failRead) throw StateError('read');
    return {...records};
  }

  @override
  Future<void> set(String identity, bool value) async {
    writes++;
    await pending?.future;
    if (failWrite) throw StateError('write');
    if (value) {
      records.add(identity);
      unresolved = unresolved.where((p) => p.identity != identity).toList();
    } else {
      records.remove(identity);
      sources.remove(identity);
    }
  }

  @override
  Future<void> close() async {}
}

void main() {
  test(
    'Recent uses inclusive rolling milliseconds and added-time ordering/day',
    () {
      final now = DateTime.utc(2026, 10, 4, 12);
      final ms = now.millisecondsSinceEpoch;
      final lower = ms - const Duration(days: 30).inMilliseconds;
      expect(inRecent(lower - 1, ms), false);
      expect(inRecent(lower, ms), true);
      expect(inRecent(ms, ms), true);
      expect(inRecent(ms + 1, ms), false);
      expect(inRecent(0, ms), false);
      final items = [
        photo(1, taken: ms + 999999, added: (lower ~/ 1000)),
        photo(2, taken: 1, added: ms ~/ 1000),
        photo(3, added: ms ~/ 1000),
        photo(4),
      ];
      final result = viewPhotos(items, LibraryView.recent, null, now);
      expect(result.map((p) => p.id), [3, 2, 1]);
      expect(viewDay(result[1], LibraryView.recent), '2026-10-04');
      expect(viewPhotos(items, LibraryView.images, null, now), items);
      expect(
        viewPhotos(
          items,
          LibraryView.recent,
          null,
          now.add(const Duration(minutes: 1)),
        ).map((p) => p.id),
        [3, 2],
      );
    },
  );
  test('only confirmed writes show; duplicates busy; read/write failures preserve records', () async {
    final b = PhotoBrowser(FakeMedia()..items = [photo(1)]);
    await b.refresh();
    final store = MemoryFavorites(), f = Favorites(MemoryFavorites(), b);
    f.dispose();
    final favorites = Favorites(store, b);
    await favorites.load();
    store.pending = Completer<void>();
    final saving = favorites.set(photo(1), true);
    await Future<void>.delayed(Duration.zero);
    expect(favorites.busy(photo(1)), true);
    expect(favorites.contains(photo(1)), false);
    await favorites.set(photo(1), true);
    expect(store.writes, 1);
    store.pending!.complete();
    await saving;
    expect(favorites.contains(photo(1)), true);
    store.failWrite = true;
    await favorites.set(photo(1), false);
    expect(favorites.contains(photo(1)), true);
    expect(favorites.failed(photo(1)), true);
    store.failRead = true;
    await favorites.load();
    expect(favorites.phase, FavoritePhase.failed);
    expect(store.records.length, 1);
    store.failRead = false;
    await favorites.load();
    expect(favorites.recordCount, 1);
    favorites.dispose();
    b.dispose();
  });
  test('permission shrink hides only; moved identity restores; version/ID reuse never inherits', () async {
    final source = FakeMedia()..items = [photo(1, added: 100)];
    final b = PhotoBrowser(source);
    await b.refresh();
    final store = MemoryFavorites(),
        favorites = Favorites(MemoryFavorites(), b);
    favorites.dispose();
    final f = Favorites(store, b);
    await f.load();
    await f.set(source.items.first, true);
    source.items = [];
    await b.refresh();
    expect(f.recordCount, 1);
    expect(
      viewPhotos(b.photos, LibraryView.favorite, f, DateTime.now()),
      isEmpty,
    );
    source.items = [photo(1, added: 100, directory: 'Pictures/Moved/')];
    await b.refresh();
    expect(f.contains(source.items.first), true);
    source.items = [photo(1, added: 101)];
    await b.refresh();
    expect(f.contains(source.items.first), false);
    source.items = [photo(1, added: 100)];
    source.version = 'rebuilt';
    await b.refresh();
    expect(f.contains(source.items.first), false);
    source.version = null;
    await b.refresh();
    expect(f.contains(source.items.first), false);
    expect(store.records.length, 1);
    source.version = 'test-library';
    await b.refresh();
    expect(f.contains(source.items.first), true);
    f.dispose();
    b.dispose();
  });
}

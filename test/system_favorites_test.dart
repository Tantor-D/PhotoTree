import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/library/favorites.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/media/system_favorites.dart';
import 'package:phototree/storage/operation_guard.dart';

import 'library_views_test.dart' show MemoryFavorites;
import 'media_browser_test.dart' show FakeMedia;

Photo item(int id, bool? value) =>
    Photo(id: id, directory: 'Pictures/Test/', systemFavorite: value);

class FakeSystem implements SystemFavoriteAccess {
  @override
  bool requestsSupported = true;
  int calls = 0;
  bool? pendingRequest = false;
  int pendingChecks = 0;
  @override
  Future<bool?> hasPendingRequest() async {
    pendingChecks++;
    return pendingRequest;
  }

  Future<SystemFavoriteResult> Function(Photo, bool)? action;
  @override
  Future<SystemFavoriteResult> set(
    Photo photo,
    String version,
    bool value,
  ) async {
    calls++;
    return action == null
        ? const SystemFavoriteResult(SystemFavoriteOutcome.cancelled)
        : action!(photo, value);
  }
}

class SyncMemory extends MemoryFavorites implements FavoriteSyncStore {
  bool enabled = false;
  final origins = <String, bool>{};
  @override
  Future<({bool enabled, Map<String, bool> origins})> readSync() async =>
      (enabled: enabled, origins: Map.of(origins));
  @override
  Future<void> saveSync({
    bool? enabled,
    required Map<String, bool> observed,
    required Set<String> removed,
    String? addPrivate,
  }) async {
    if (failWrite) throw StateError('write');
    this.enabled = enabled ?? this.enabled;
    origins.addAll(observed);
    for (final id in removed) {
      origins.remove(id);
      records.remove(id);
    }
    if (addPrivate != null) records.add(addPrivate);
  }
}

class CountingPhotos extends ListBase<Photo> {
  CountingPhotos(this.items);
  final List<Photo> items;
  int reads = 0;
  @override
  int get length => items.length;
  @override
  set length(int _) => throw UnsupportedError('immutable');
  @override
  Photo operator [](int index) {
    reads++;
    return items[index];
  }

  @override
  void operator []=(int index, Photo value) =>
      throw UnsupportedError('immutable');
}

class IndexedTestBrowser extends PhotoBrowser {
  IndexedTestBrowser(this.currentPhotos) : super(FakeMedia());
  List<Photo> currentPhotos;
  BrowsePhase currentPhase = BrowsePhase.ready;
  String version = 'library';
  @override
  List<Photo> get photos => currentPhotos;
  @override
  BrowsePhase get phase => currentPhase;
  @override
  String? get libraryVersion => version;
}

void main() {
  test(
    'native confirmed change keeps provenance while browser is suspended',
    () async {
      final source = FakeMedia()..items = [item(1, false)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final store = SyncMemory()..enabled = true;
      final system = FakeSystem()
        ..action = (photo, value) async {
          browser.suspend();
          source.items = [item(1, true)];
          return const SystemFavoriteResult(
            SystemFavoriteOutcome.confirmed,
            value: true,
            changed: true,
          );
        };
      final favorites = Favorites(
        store,
        browser,
        system: system,
        syncStore: store,
      );
      await favorites.load();
      await Future<void>.delayed(Duration.zero);
      final id = favoriteIdentity(source.items.single, browser.libraryVersion)!;
      await favorites.set(source.items.single, true);
      expect(store.records, contains(id));
      expect(store.origins[id], true);
      await browser.refresh();
      expect(await favorites.setImageSync(false), true);
      expect(favorites.contains(source.items.single), true);
      favorites.dispose();
      browser.dispose();
    },
  );
  test(
    'image sync is opt-in; external removal survives disable and restart',
    () async {
      const video = Photo(
        id: 3,
        directory: 'Pictures/Test/',
        kind: MediaKind.video,
        systemFavorite: true,
      );
      final source = FakeMedia()
        ..items = [item(1, false), item(2, true), video];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final store = SyncMemory();
      final system = FakeSystem()
        ..action = (p, value) async {
          source.items = [item(1, value), item(2, true), video];
          return SystemFavoriteResult(
            SystemFavoriteOutcome.confirmed,
            value: value,
            changed: true,
          );
        };
      Favorites open() =>
          Favorites(store, browser, system: system, syncStore: store);
      var favorites = open();
      await favorites.load();
      await Future<void>.delayed(Duration.zero);
      expect(favorites.contains(source.items[1]), false);
      expect(await favorites.setImageSync(true), true);
      expect(system.calls, 0);
      expect(favorites.contains(source.items[1]), true);
      expect(favorites.contains(video), false);
      await favorites.set(source.items.first, true);
      final id = favoriteIdentity(source.items.first, browser.libraryVersion)!;
      expect(store.origins[id], true);
      expect(store.records, contains(id));
      source.items = [item(1, null), item(2, true), video];
      await browser.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(store.records, contains(id));
      expect(await favorites.setImageSync(false), false);
      expect(store.enabled, true);
      source.items = [item(1, false), item(2, true), video];
      await browser.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(store.records, isNot(contains(id)));
      expect(favorites.contains(source.items.first), false);
      favorites.dispose();
      favorites = open();
      await favorites.load();
      await Future<void>.delayed(Duration.zero);
      expect(favorites.systemMode, true);
      expect(await favorites.setImageSync(false), true);
      expect(favorites.contains(source.items[1]), false);
      favorites.dispose();
      favorites = open();
      await favorites.load();
      await Future<void>.delayed(Duration.zero);
      expect(favorites.systemMode, false);
      expect(favorites.contains(source.items.first), false);
      expect(system.calls, 1);
      favorites.dispose();
      browser.dispose();
    },
  );

  test('favorite lookup scales linearly and invalidates permission and list changes', () async {
    final photos = List.generate(1000, (index) => item(index + 1, true));
    final counted = CountingPhotos(photos);
    final browser = IndexedTestBrowser(counted);
    final favorites = Favorites(
      MemoryFavorites(),
      browser,
      system: FakeSystem(),
    );
    await favorites.load();
    for (final photo in photos) {
      expect(favorites.contains(photo), true);
    }
    expect(counted.reads, lessThanOrEqualTo(1000));
    browser.currentPhase = BrowsePhase.denied;
    expect(favorites.state(photos.first), isNull);
    browser.currentPhase = BrowsePhase.ready;
    browser.currentPhotos = [item(1, false)];
    expect(favorites.state(photos.first), false);
    browser.currentPhotos = [item(1, true), item(1, true)];
    expect(favorites.state(photos.first), isNull);
    browser.currentPhotos = [item(1, true)];
    expect(favorites.state(photos.first), true);
    browser.version = 'rebuilt';
    expect(favorites.state(photos.first), true);
    favorites.dispose();
    browser.dispose();
  });

  test(
    'unverified uses private records; verified uses only readable system state',
    () async {
      final source = FakeMedia()..items = [item(1, false), item(2, null)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final store = MemoryFavorites();
      final system = FakeSystem()..requestsSupported = false;
      final favorites = Favorites(store, browser, system: system);
      await favorites.load();
      await favorites.set(source.items.first, true);
      expect(favorites.contains(source.items.first), true);
      expect(system.calls, 0);
      system.requestsSupported = true;
      expect(favorites.contains(source.items.first), false);
      expect(favorites.state(source.items.last), null);
      expect(favorites.canSet(source.items.last), false);
      await favorites.set(source.items.last, true);
      expect(system.calls, 0);
      expect(
        favorites.resultFor(source.items.last),
        SystemFavoriteOutcome.unknown,
      );
      expect(store.records, hasLength(1));
      browser.suspend();
      expect(favorites.state(source.items.first), null);
      favorites.dispose();
      browser.dispose();
    },
  );

  test(
    'confirmation requires fresh read, shared guard and duplicate exclusion',
    () async {
      final source = FakeMedia()..items = [item(1, false), item(2, false)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final guard = BackupOperationGuard();
      final system = FakeSystem();
      final result = Completer<SystemFavoriteResult>();
      system.action = (_, _) => result.future;
      final favorites = Favorites(
        MemoryFavorites(),
        browser,
        system: system,
        guard: guard,
      );
      await favorites.load();
      final saving = favorites.set(source.items.first, true);
      await Future<void>.delayed(Duration.zero);
      await favorites.set(source.items.last, true);
      expect(system.calls, 1);
      expect(() => guard.acquire(Object()), throwsStateError);
      expect(favorites.contains(source.items.first), false);
      result.complete(
        const SystemFavoriteResult(
          SystemFavoriteOutcome.confirmed,
          value: true,
        ),
      );
      await saving;
      expect(
        favorites.resultFor(source.items.first),
        SystemFavoriteOutcome.unknown,
      );
      system.action = (photo, value) async {
        source.items = [item(1, true), item(2, false)];
        return const SystemFavoriteResult(
          SystemFavoriteOutcome.confirmed,
          value: true,
        );
      };
      await favorites.set(source.items.first, true);
      expect(
        favorites.resultFor(source.items.first),
        SystemFavoriteOutcome.confirmed,
      );
      expect(favorites.contains(source.items.first), true);
      final owner = Object();
      guard.acquire(owner);
      await favorites.set(source.items.first, false);
      expect(
        favorites.resultFor(source.items.first),
        SystemFavoriteOutcome.busy,
      );
      expect(system.calls, 2);
      guard.release(owner);
      favorites.dispose();
      browser.dispose();
    },
  );

  test(
    'background callback is unknown and restart never replays migration',
    () async {
      final source = FakeMedia()..items = [item(1, false)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final photo = source.items.first;
      final id = favoriteIdentity(photo, browser.libraryVersion)!;
      final store = MemoryFavorites()..records.add(id);
      final system = FakeSystem()
        ..action = (_, _) async {
          browser.suspend();
          return const SystemFavoriteResult(
            SystemFavoriteOutcome.confirmed,
            value: true,
          );
        };
      final favorites = Favorites(store, browser, system: system);
      await favorites.load();
      await favorites.migrateSelected({id});
      expect(favorites.resultFor(photo), isNull);
      expect(store.migrationOutcomes[id], 'unknown');
      expect(store.records, contains(id));
      await favorites.load();
      expect(system.calls, 1);
      expect(browser.foreground, false);
      favorites.dispose();
      browser.dispose();
    },
  );

  test(
    'migration only selected identities, stops on cancel, preserves sources',
    () async {
      final source = FakeMedia()
        ..items = [item(1, false), item(2, false), item(3, true)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final ids = {
        for (final p in source.items)
          favoriteIdentity(p, browser.libraryVersion)!,
      };
      final store = MemoryFavorites()..records.addAll(ids);
      final system = FakeSystem();
      final favorites = Favorites(store, browser, system: system);
      await favorites.load();
      final already = favoriteIdentity(
        source.items.last,
        browser.libraryVersion,
      )!;
      await favorites.migrateSelected({already});
      expect(system.calls, 0);
      expect(store.migrationOutcomes[already], 'confirmed');
      await favorites.migrateSelected(ids.difference({already}));
      expect(system.calls, 1);
      expect(
        store.migrationOutcomes.values.where((v) => v == 'cancelled'),
        hasLength(1),
      );
      expect(store.records, ids);
      expect(favorites.migrationCandidates, hasLength(3));
      favorites.dispose();
      browser.dispose();
    },
  );

  test('restore-held and stale identities cannot submit; durable intent failure prevents migration', () async {
    final source = FakeMedia()..items = [item(1, false)];
    final browser = PhotoBrowser(source);
    await browser.refresh();
    final old = source.items.first;
    final identity = favoriteIdentity(old, browser.libraryVersion)!;
    final store = MemoryFavorites()..records.add(identity);
    final system = FakeSystem();
    final favorites = Favorites(store, browser, system: system);
    await favorites.load();
    await favorites.holdForBackup();
    await favorites.set(old, true);
    expect(system.calls, 0);
    favorites.releaseBackup();
    store.failWrite = true;
    await favorites.migrateSelected({identity});
    expect(system.calls, 0);
    expect(favorites.migrationOutcomes[identity], 'unknown');
    store.failWrite = false;
    source.items = [
      Photo(
        id: 1,
        directory: 'Pictures/Test/',
        addedSeconds: 99,
        systemFavorite: false,
      ),
    ];
    await browser.refresh();
    expect(favorites.migrationCandidates, isEmpty);
    expect(favorites.migrationUnavailableCount, 1);
    await favorites.set(old, true);
    expect(system.calls, 0);
    expect(favorites.resultFor(old), SystemFavoriteOutcome.stale);
    favorites.dispose();
    browser.dispose();
  });

  test(
    'ordinary refresh preserves system favorite view and disables writes',
    () async {
      final source = FakeMedia()..items = [item(1, true)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final favorites = Favorites(
        MemoryFavorites(),
        browser,
        system: FakeSystem(),
      );
      await favorites.load();
      final page = Completer<List<Photo>>();
      source.query = (after) async => after == 0 ? page.future : [];
      final refresh = browser.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(browser.updating, true);
      expect(favorites.contains(source.items.first), true);
      expect(favorites.canSet(source.items.first), false);
      page.complete(source.items);
      await refresh;
      favorites.dispose();
      browser.dispose();
    },
  );

  test(
    'migration binds selected library version and cannot cross a rebuild',
    () async {
      final source = FakeMedia()..items = [item(1, false), item(2, false)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final ids = {
        for (final p in source.items)
          favoriteIdentity(p, browser.libraryVersion)!,
      };
      final store = MemoryFavorites()..records.addAll(ids);
      final system = FakeSystem()
        ..action = (_, _) async {
          source.version = 'rebuilt';
          source.items = [item(1, true), item(2, true)];
          return const SystemFavoriteResult(
            SystemFavoriteOutcome.confirmed,
            value: true,
          );
        };
      final favorites = Favorites(store, browser, system: system);
      await favorites.load();
      await favorites.migrateSelected(ids);
      expect(system.calls, 1);
      expect(favorites.resultFor(source.items.first), isNull);
      expect(store.records, ids);
      expect(store.migrationOutcomes.values, ['unknown']);
      favorites.dispose();
      browser.dispose();
    },
  );

  test('ordinary system requests persist unknown before writing and restart never replays', () async {
    final source = FakeMedia()..items = [item(1, false)];
    final browser = PhotoBrowser(source);
    await browser.refresh();
    final photo = source.items.first;
    final identity = favoriteIdentity(photo, browser.libraryVersion)!;
    final store = MemoryFavorites();
    final system = FakeSystem()
      ..action = (_, _) async {
        expect(store.migrationOutcomes[identity], 'unknown');
        throw StateError('callback lost');
      };
    final favorites = Favorites(store, browser, system: system);
    await favorites.load();
    await favorites.set(photo, true);
    expect(system.calls, 1);
    expect(store.migrationOutcomes[identity], 'unknown');
    expect(store.records, isEmpty);
    final restarted = Favorites(store, browser, system: system);
    await restarted.load();
    expect(restarted.resultFor(photo), SystemFavoriteOutcome.unknown);
    expect(system.calls, 1);
    system.action = (_, _) async =>
        const SystemFavoriteResult(SystemFavoriteOutcome.cancelled);
    await restarted.set(photo, true);
    expect(store.migrationOutcomes[identity], 'cancelled');
    favorites.dispose();
    restarted.dispose();
    browser.dispose();
  });

  test(
    'ordinary system request cannot write if pending result cannot be saved',
    () async {
      final source = FakeMedia()..items = [item(1, false)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final store = MemoryFavorites()..failWrite = true;
      final system = FakeSystem();
      final favorites = Favorites(store, browser, system: system);
      await favorites.load();
      await favorites.set(source.items.first, true);
      expect(system.calls, 0);
      expect(
        favorites.resultFor(source.items.first),
        SystemFavoriteOutcome.unknown,
      );
      expect(store.migrationOutcomes, isEmpty);
      favorites.dispose();
      browser.dispose();
    },
  );

  test('unknown active system request retains the shared guard', () async {
    final source = FakeMedia()..items = [item(1, false), item(2, false)];
    final browser = PhotoBrowser(source);
    await browser.refresh();
    final guard = BackupOperationGuard();
    final system = FakeSystem();
    system.action = (_, _) async {
      system.pendingRequest = true;
      return const SystemFavoriteResult(
        SystemFavoriteOutcome.unknown,
        pending: true,
      );
    };
    final favorites = Favorites(
      MemoryFavorites(),
      browser,
      system: system,
      guard: guard,
    );
    await favorites.load();
    await favorites.set(source.items.first, true);
    expect(system.calls, 1);
    expect(guard.held, true);
    expect(() => guard.acquire(Object()), throwsStateError);
    await favorites.set(source.items.last, true);
    expect(system.calls, 1);
    final history = Map.of(favorites.migrationOutcomes);
    expect(favorites.systemRequestPending, true);
    system.pendingRequest = null;
    expect(await favorites.reconcileSystemRequest(), false);
    expect(guard.held, true);
    system.pendingRequest = false;
    expect(await favorites.reconcileSystemRequest(), true);
    expect(guard.held, false);
    expect(favorites.systemRequestPending, false);
    expect(favorites.migrationOutcomes, history);
    expect(system.calls, 1);
    favorites.dispose();
    browser.dispose();
  });

  test(
    'recreated Favorites checks pending before private data can load',
    () async {
      final browser = PhotoBrowser(FakeMedia()..items = [item(1, false)]);
      await browser.refresh();
      final identity = favoriteIdentity(
        browser.photos.single,
        browser.libraryVersion,
      )!;
      final store = MemoryFavorites()..migrationOutcomes[identity] = 'unknown';
      final guard = BackupOperationGuard();
      final system = FakeSystem()..pendingRequest = true;
      final recreated = Favorites(store, browser, system: system, guard: guard);
      await recreated.load();
      expect(recreated.phase, FavoritePhase.loading);
      expect(recreated.systemRequestPending, true);
      expect(guard.held, true);
      expect(system.calls, 0);
      system.pendingRequest = false;
      await recreated.load();
      expect(recreated.phase, FavoritePhase.ready);
      expect(
        recreated.resultFor(browser.photos.single),
        SystemFavoriteOutcome.unknown,
      );
      expect(guard.held, false);
      expect(system.calls, 0);
      recreated.dispose();
      browser.dispose();
    },
  );

  test(
    'unverified mode does not query native pending or retain a guard',
    () async {
      final browser = PhotoBrowser(FakeMedia()..items = [item(1, false)]);
      await browser.refresh();
      final system = FakeSystem()
        ..requestsSupported = false
        ..pendingRequest = true;
      final guard = BackupOperationGuard();
      final favorites = Favorites(
        MemoryFavorites(),
        browser,
        system: system,
        guard: guard,
      );
      await favorites.load();
      await favorites.reconcileSystemRequest();
      await favorites.set(browser.photos.single, true);
      expect(favorites.contains(browser.photos.single), true);
      expect(system.pendingChecks, 0);
      expect(system.calls, 0);
      expect(guard.held, false);
      favorites.dispose();
      browser.dispose();
    },
  );

  test(
    'pending sources preserve old shape and reject unknown outcome/source',
    () {
      final legacy = PendingFavorite(identity: 'id', reason: 'missing');
      expect(pendingData(legacy), hasLength(6));
      expect(pendingFrom(pendingData(legacy)).source, 'legacy');
      final system = PendingFavorite(
        identity: 'id',
        reason: 'waiting',
        source: 'system',
      );
      expect(pendingFrom(pendingData(system)).source, 'system');
      expect(
        () => FavoriteSnapshot([], [
          PendingFavorite(identity: 'id', reason: 'x', source: 'bad'),
        ]),
        throwsStateError,
      );
      expect(() => FavoriteSnapshot([], [], {'id': 'bad'}), throwsStateError);
    },
  );
}

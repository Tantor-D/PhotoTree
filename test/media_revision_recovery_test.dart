import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/library/favorites.dart';
import 'package:phototree/library/physical_operations.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/media/physical_media.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/storage/operation_guard.dart';
import 'package:phototree/ui/photo_grid.dart';

import 'library_views_test.dart' show MemoryFavorites;
import 'media_browser_test.dart' show FakeMedia, photo;
import 'organization_test.dart' show MemoryOrganization;
import 'physical_operations_test.dart' show Access, Journal;

class RevisionMedia extends FakeMedia {
  final events = StreamController<void>.broadcast(sync: true);
  int reads = 0, permissionRequests = 0, reselections = 0;
  @override
  Stream<void> get changes => events.stream;
  @override
  Future<List<Photo>> page({required int afterId}) {
    if (afterId == 0) reads++;
    return super.page(afterId: afterId);
  }

  @override
  Future<MediaPermissions> permission({bool request = false}) {
    if (request) permissionRequests++;
    return super.permission(request: request);
  }

  @override
  Future<void> reselect() async => reselections++;
}

void main() {
  testWidgets(
    'mixed delete settles after silent generation advance without replay',
    (tester) async {
      final media = RevisionMedia()
        ..items = [
          photo(1),
          const Photo(id: 2, directory: 'Pictures/A/', kind: MediaKind.video),
          photo(3),
        ];
      final browser = PhotoBrowser(media);
      final guard = BackupOperationGuard();
      final favorites = Favorites(MemoryFavorites(), browser, guard: guard);
      final organization = Organization(
        MemoryOrganization(),
        browser,
        operationGuard: guard,
      );
      final access = Access();
      final journal = Journal();
      final ops = PhysicalOperations(
        organization,
        favorites,
        browser,
        access,
        journal,
        guard: guard,
      );
      await browser.refresh();
      await favorites.load();
      await organization.load();
      await ops.initialize();
      await ops.preparePhotos(
        media.items.take(2).toList(),
        kind: PhysicalKind.delete,
      );
      var invalidated = false;
      var readsBeforeFinalRefresh = 0;
      access.action = () async {
        media.items = media.items.where((p) => p.id != access.writes).toList();
        media.revision = media.revision! + 1;
        media.events.add(null);
        if (access.writes == 2) {
          readsBeforeFinalRefresh = media.reads;
          media.query = (after) async {
            if (!invalidated) {
              invalidated = true;
              // A provider transaction advances the token without another event.
              media.revision = media.revision! + 3;
              return [photo(99)];
            }
            return media.items.where((p) => p.id > after).toList();
          };
        }
        return const PhysicalResult(PhysicalOutcome.confirmed);
      };
      final published = <List<int>>[];
      final phases = <BrowsePhase>[];
      browser.addListener(() {
        published.add(browser.photos.map((p) => p.id).toList());
        phases.add(browser.phase);
      });
      await ops.execute();
      expect(browser.phase, BrowsePhase.ready);
      expect(browser.failure, isNull);
      expect(browser.photos.map((p) => p.id), [3]);
      expect(browser.collectionRevision, media.revision);
      expect(media.reads - readsBeforeFinalRefresh, 2);
      expect(phases, isNot(contains(BrowsePhase.failed)));
      expect(published.expand((p) => p), isNot(contains(99)));
      expect(access.writes, 2);
      expect(access.authorizationGroups, hasLength(1));
      expect(ops.records.single.items.every((i) => i.privateCommitted), isTrue);
      final journalWrites = journal.writes;
      await tester.pumpWidget(MaterialApp(home: MediaStatus(browser: browser)));
      expect(find.text('媒体读取失败，请重试'), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      expect(media.reads - readsBeforeFinalRefresh, 2);
      expect(access.writes, 2);
      expect(journal.writes, journalWrites);
      await tester.pumpWidget(const SizedBox());
      ops.dispose();
      organization.dispose();
      favorites.dispose();
      browser.dispose();
      await media.events.close();
    },
  );

  testWidgets(
    'second invalidation fails and stays failed until explicit refresh',
    (tester) async {
      final media = RevisionMedia();
      media.query = (after) async {
        if (after == 0) {
          media.revision = media.revision! + 1;
          return [photo(1)];
        }
        return [];
      };
      final browser = PhotoBrowser(media);
      await browser.refresh(request: true, reselect: true);
      expect(browser.phase, BrowsePhase.failed);
      expect(browser.failure, MediaFailureKind.stale);
      expect(browser.photos, isEmpty);
      expect(media.reads, 2);
      expect(media.permissionRequests, 1);
      expect(media.reselections, 1);
      expect(await browser.waitForRefresh(), isFalse);
      await tester.pumpWidget(MaterialApp(home: MediaStatus(browser: browser)));
      expect(find.text('媒体读取失败，请重试'), findsOneWidget);
      await tester.pump(const Duration(seconds: 30));
      expect(media.reads, 2);
      media.query = null;
      await browser.refresh();
      expect(browser.phase, BrowsePhase.ready);
      expect(media.reads, 3);
      await tester.pumpWidget(const SizedBox());
      browser.dispose();
      await media.events.close();
    },
  );

  for (final fault in [
    'query',
    'permission',
    'attribution',
    'stale exception',
    'conversion',
    'image access',
    'video access',
    'limited',
    'version changed',
    'version unknown',
    'version empty',
    'version becomes unknown',
    'revision unknown',
    'revision becomes unknown',
    'revision backwards',
    'revision equal',
  ]) {
    test('does not recover unsupported invalidation: $fault', () async {
      final media = RevisionMedia();
      if (fault == 'version unknown') media.version = null;
      if (fault == 'version empty') media.version = '';
      if (fault == 'revision unknown') media.revision = null;
      if (fault == 'limited') media.videoAccess = PhotoAccess.limited;
      media.query = (after) async {
        if (after != 0) return [];
        media.revision = fault == 'revision equal' ? 1 : 4;
        switch (fault) {
          case 'query':
            throw const MediaFailure(MediaFailureKind.query);
          case 'permission':
            throw const MediaFailure(MediaFailureKind.permission);
          case 'attribution':
            return [photo(1, directory: '')];
          case 'stale exception':
            throw const MediaFailure(MediaFailureKind.stale);
          case 'conversion':
            throw const FormatException('invalid row');
          case 'image access':
            media.access = PhotoAccess.limited;
          case 'video access':
            media.videoAccess = PhotoAccess.denied;
          case 'version changed':
            media.version = 'another-library';
          case 'version becomes unknown':
            media.version = null;
          case 'revision becomes unknown':
            media.revision = null;
          case 'revision backwards':
            media.revision = 0;
        }
        return [photo(1)];
      };
      final browser = PhotoBrowser(media);
      await browser.refresh();
      expect(media.reads, 1);
      if (fault == 'revision equal') {
        expect(browser.phase, BrowsePhase.ready);
      } else {
        expect(
          browser.phase,
          fault == 'permission' ? BrowsePhase.denied : BrowsePhase.failed,
        );
        expect(browser.photos, isEmpty);
      }
      browser.dispose();
      await media.events.close();
    });
  }

  for (final end in [
    'ready',
    'new refresh',
    'notification',
    'background',
    'dispose',
  ]) {
    testWidgets('pending replacement and refresh waiters: $end', (
      tester,
    ) async {
      final media = RevisionMedia();
      final replacement = Completer<List<Photo>>();
      media.query = (after) async {
        if (after != 0) return [];
        if (media.reads == 1) {
          media.revision = 4;
          return [photo(99)];
        }
        return replacement.future;
      };
      final browser = PhotoBrowser(media);
      final published = <int>[];
      browser.addListener(
        () => published.addAll(browser.photos.map((p) => p.id)),
      );
      final work = browser.refresh();
      bool? settled;
      final waiting = browser.waitForRefresh().then((value) => settled = value);
      await tester.pump();
      expect(media.reads, 2);
      expect(settled, isNull);
      expect(browser.photos, isEmpty);
      expect(browser.phase, BrowsePhase.loading);
      if (end == 'new refresh' || end == 'notification') {
        media.query = null;
        media.items = [photo(3)];
      }
      switch (end) {
        case 'new refresh':
          await browser.refresh();
        case 'notification':
          media.events.add(null);
          await tester.pump(const Duration(milliseconds: 151));
        case 'background':
          browser.suspend();
        case 'dispose':
          browser.dispose();
      }
      replacement.complete([photo(2)]);
      await work;
      await waiting;
      expect(settled, end != 'background' && end != 'dispose');
      expect(published, isNot(contains(99)));
      if (end == 'ready') {
        expect(browser.photos.single.id, 2);
      } else {
        expect(published, isNot(contains(2)));
      }
      expect(
        media.reads,
        end == 'new refresh' || end == 'notification' ? 3 : 2,
      );
      if (end != 'dispose') browser.dispose();
      await media.events.close();
    });
  }
}

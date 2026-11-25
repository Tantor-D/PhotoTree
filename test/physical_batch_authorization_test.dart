import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/library/physical_operations.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/media/physical_media.dart';

import 'physical_operations_test.dart' show Harness;

void main() {
  late Harness h;
  setUp(() async {
    h = Harness();
    await h.init();
  });
  tearDown(() => h.dispose());

  test(
    'mixed batch authorizes exact group once before any item write',
    () async {
      h.media.items = [
        const Photo(id: 1, directory: 'Pictures/A/'),
        const Photo(id: 2, directory: 'Pictures/A/', kind: MediaKind.video),
      ];
      await h.browser.refresh();
      h.access.authorizing = () async {
        expect(h.access.writes, 0);
        expect(h.journal.data.values.single.authorizationPending, isTrue);
        expect(h.guard.held, isTrue);
        return const PhysicalResult(PhysicalOutcome.confirmed);
      };
      await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
      await h.ops.execute();
      expect(
        h.access.authorizationGroups.single.map((s) => s.photo.kind),
        [MediaKind.video, MediaKind.image].reversed.toList(),
      );
      expect(h.access.writes, 2);
      expect(h.ops.records.single.authorizationPending, isFalse);
    },
  );

  for (final outcome in [
    PhysicalOutcome.cancelled,
    PhysicalOutcome.permission,
    PhysicalOutcome.stale,
  ]) {
    test('authorization $outcome stops whole batch without writes', () async {
      h.access.authorizationOutcome = outcome;
      await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
      await h.ops.execute();
      expect(h.access.writes, 0);
      expect(
        h.ops.records.single.items.every((i) => i.outcome == outcome),
        isTrue,
      );
      expect(h.guard.held, isFalse);
    });
  }
  test(
    'cancel and duplicate execute while authorization is pending never write',
    () async {
      final gate = Completer<PhysicalResult>();
      h.access.authorizing = () => gate.future;
      await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
      final executing = h.ops.execute();
      while (h.access.authorizationGroups.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await h.ops.execute();
      h.ops.cancelRemaining();
      gate.complete(const PhysicalResult(PhysicalOutcome.confirmed));
      await executing;
      expect(h.access.authorizationGroups.length, 1);
      expect(h.access.writes, 0);
      expect(
        h.ops.records.single.items.every(
          (i) => i.outcome == PhysicalOutcome.cancelled,
        ),
        isTrue,
      );
    },
  );
  test('unknown authorization keeps lease until native idle then recovery cancels queued items', () async {
    h.access.authorizationOutcome = PhysicalOutcome.unknown;
    h.access.pendingAuthorization = PhysicalOutcome.busy;
    await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
    await h.ops.execute();
    expect(h.ops.blocked, isTrue);
    expect(h.guard.held, isTrue);
    await h.ops.reconcile();
    expect(h.guard.held, isTrue);
    expect(h.ops.records.single.authorizationPending, isTrue);
    h.access.pendingAuthorization = PhysicalOutcome.confirmed;
    await h.ops.reconcile();
    expect(h.guard.held, isFalse);
    expect(h.access.writes, 0);
    expect(h.access.authorizationGroups.length, 1);
    expect(
      h.ops.records.single.items.every(
        (i) => i.outcome == PhysicalOutcome.cancelled,
      ),
      isTrue,
    );
  });
  test(
    'failure to persist authorization phase cannot launch system request',
    () async {
      h.journal.failAt = 2;
      await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
      await h.ops.execute();
      expect(h.access.authorizationGroups, isEmpty);
      expect(h.access.writes, 0);
      expect(h.ops.blocked, isTrue);
    },
  );
  test('permission loss after first item stops unstarted items without prompting again', () async {
    h.access.action = () async =>
        const PhysicalResult(PhysicalOutcome.permission);
    await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
    await h.ops.execute();
    expect(h.access.writes, 1);
    expect(h.access.authorizationGroups.length, 1);
    expect(h.ops.records.single.items.last.outcome, PhysicalOutcome.cancelled);
  });
  test('large selection preserves grouping and later denial leaves every item unwritten', () async {
    h.media.items = List.generate(
      501,
      (i) => Photo(id: i + 1, directory: 'Pictures/A/'),
    );
    await h.browser.refresh();
    h.access.authorizing = () async => PhysicalResult(
      h.access.authorizationGroups.length == 1
          ? PhysicalOutcome.confirmed
          : PhysicalOutcome.cancelled,
    );
    await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
    await h.ops.execute();
    expect(h.access.authorizationGroups.map((g) => g.length), [500, 1]);
    expect(h.access.writes, 0);
    expect(
      h.ops.records.single.items.every(
        (i) => i.outcome == PhysicalOutcome.cancelled,
      ),
      isTrue,
    );
  });

  test('completed cancelled batch reopens without requiring journal writes', () async {
    h.media.items = List.generate(
      501,
      (i) => Photo(id: i + 1, directory: 'Pictures/A/'),
    );
    await h.browser.refresh();
    h.access.authorizing = () async => PhysicalResult(
      h.access.authorizationGroups.length == 1
          ? PhysicalOutcome.confirmed
          : PhysicalOutcome.cancelled,
    );
    await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
    await h.ops.execute();
    final saved = h.ops.records.single.encode();
    final writes = h.journal.writes;
    h.journal.failAt = writes + 1;

    await h.ops.reconcile();

    expect(h.ops.blocked, isFalse);
    expect(h.ops.busy, isFalse);
    expect(h.ops.records.single.encode(), saved);
    expect(h.journal.writes, writes);
    expect(h.access.writes, 0);
    expect(h.access.authorizationGroups.length, 2);
  });

  test(
    'old canonical journals remain byte compatible without authorization field',
    () async {
      final b = await h.ops.preparePhotos(
        h.media.items,
        kind: PhysicalKind.delete,
      );
      expect(b!.encode(), isNot(contains('authorizationPending')));
      expect(PhysicalBatch.decode(b.encode()).encode(), b.encode());
      final pending = b.copy(authorizationPending: true);
      expect(
        PhysicalBatch.decode(pending.encode()).authorizationPending,
        isTrue,
      );
    },
  );
}

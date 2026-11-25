import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/library/favorites.dart';
import 'package:phototree/library/physical_operations.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/media/physical_media.dart';

import 'physical_operations_test.dart' show Harness, snap;

void main() {
  const image = Photo(id: 7, directory: 'Pictures/A/');
  const video = Photo(
    id: 7,
    directory: 'Pictures/A/',
    kind: MediaKind.video,
    durationMs: 12000,
  );
  late Harness h;
  setUp(() async {
    h = Harness();
    h.media.items = [video, image];
    await h.init();
  });
  tearDown(() => h.dispose());

  test('mixed same-number preview cancellation leaves both favorites and no intent', () async {
    final before = Set<String>.of(h.fs.records);
    await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
    expect(h.ops.preview!.items.map((i) => i.snapshot.photo.key).toSet(), {
      video.key,
      image.key,
    });
    h.ops.cancelPreview();
    expect(h.access.writes, 0);
    expect(h.journal.writes, 0);
    expect(h.fs.records, before);
  });

  test(
    'mixed partial deletion keeps same-number image after video succeeds',
    () async {
      h.access.action = () async => PhysicalResult(
        h.access.writes == 1
            ? PhysicalOutcome.confirmed
            : PhysicalOutcome.cancelled,
      );
      await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
      await h.ops.execute();
      expect(h.access.writes, 2);
      expect(h.fs.records, {favoriteIdentity(image, h.media.version)});
      final items = h.ops.records.single.items;
      expect(items.map((i) => i.snapshot.photo.kind), [
        MediaKind.video,
        MediaKind.image,
      ]);
      expect(items.map((i) => i.outcome), [
        PhysicalOutcome.confirmed,
        PhysicalOutcome.cancelled,
      ]);
      expect(items.first.privateCommitted, true);
      expect(items.last.privateCommitted, false);
    },
  );

  test(
    'restarted mixed intent observes video once and never replays queued image',
    () async {
      final batch = PhysicalBatch(
        id: 'mixed-interrupted',
        kind: PhysicalKind.delete,
        items: [
          PhysicalItem(
            snapshot: snap(video),
            state: PhysicalItemState.inFlight,
          ),
          PhysicalItem(snapshot: snap(image)),
        ],
      );
      h.journal.data[batch.id] = PhysicalBatch.decode(batch.encode());
      await h.ops.initialize();
      expect(h.access.writes, 0);
      expect(h.access.reconciles, 1);
      expect(
        h.ops.records.single.items.first.snapshot.photo.kind,
        MediaKind.video,
      );
      expect(
        h.ops.records.single.items.last.outcome,
        PhysicalOutcome.cancelled,
      );
      expect(h.fs.records, {favoriteIdentity(image, h.media.version)});
      await h.ops.initialize();
      expect(h.access.writes, 0);
      expect(h.access.reconciles, 1);
      expect(h.fs.records, {favoriteIdentity(image, h.media.version)});
    },
  );
  test('video move rejects a confirmed same-number image result', () async {
    const wrongType = Photo(id: 7, directory: 'Pictures/B/');
    h.access.action = () async =>
        PhysicalResult(PhysicalOutcome.confirmed, after: snap(wrongType));
    final before = Set<String>.of(h.fs.records);
    await h.ops.preparePhotos(
      [video],
      kind: PhysicalKind.move,
      targetDirectory: 'Pictures/B/',
    );
    await h.ops.execute();
    expect(h.access.writes, 1);
    expect(h.ops.records.single.items.single.outcome, PhysicalOutcome.unknown);
    expect(h.ops.records.single.items.single.privateCommitted, false);
    expect(h.fs.records, before);
  });
}

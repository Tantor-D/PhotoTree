import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/media/physical_media.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.tantor_d.phototree/physicalMedia');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final access = AndroidPhysicalMediaAccess();
  const photo = Photo(id: 1, directory: 'Pictures/A/');
  const snapshot = PhysicalPhotoSnapshot(
    photo: photo,
    libraryVersion: 'v',
    displayName: 'a.jpg',
    size: 10,
    mimeType: 'image/jpeg',
    modifiedSeconds: 1,
    generationModified: 2,
    sha256: 'hash',
  );
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('batch authorization carries exact snapshots and authorized execution never uses a second method', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {'outcome': 'confirmed'};
    });
    expect(
      (await access.authorizePhotos([snapshot])).outcome,
      PhysicalOutcome.confirmed,
    );
    await access.executePhoto(PhysicalKind.delete, snapshot, authorized: true);
    expect(calls.map((c) => c.method), ['authorizePhotos', 'executePhoto']);
    expect(calls.first.arguments['photos'], [snapshot.toMap()]);
    expect(calls.last.arguments['authorized'], isTrue);
    expect(await access.authorizationState(), PhysicalOutcome.confirmed);
    expect(calls.last.method, 'authorizationState');
  });
  test('snapshot journal round trip retains complete evidence', () {
    expect(
      PhysicalPhotoSnapshot.fromMap(snapshot.toMap()).toMap(),
      snapshot.toMap(),
    );
  });
  test('recovery calls only observation with frozen evidence', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {'outcome': 'unknown'};
    });
    expect(
      (await access.reconcilePhoto(PhysicalKind.delete, snapshot)).outcome,
      PhysicalOutcome.unknown,
    );
    expect(calls.single.method, 'reconcilePhoto');
    expect(calls.single.arguments['snapshot'], snapshot.toMap());
  });
  test('directory recovery retains frozen parent and child token', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'reconcileEmptyAlbum');
      expect(call.arguments['directoryToken'], '1:2:3:4');
      return {'outcome': 'stale'};
    });
    expect(
      (await access.reconcileEmptyAlbum(
        'external_primary',
        'Pictures/A/',
        directoryToken: '1:2:3:4',
      )).outcome,
      PhysicalOutcome.stale,
    );
  });
  test('malformed platform snapshot never becomes confirmed', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'outcome': 'confirmed',
        'photos': [
          {'id': 'bad'},
        ],
      },
    );
    expect(
      (await access.prepare([photo], 'v')).outcome,
      PhysicalOutcome.unknown,
    );
  });
  test(
    'lost platform reply remains unknown rather than failed retry',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'lost'),
      );
      expect(
        (await access.executePhoto(PhysicalKind.delete, snapshot)).outcome,
        PhysicalOutcome.unknown,
      );
    },
  );
  test(
    'cancel and permission remain separate from confirmed deletion',
    () async {
      for (final outcome in ['cancelled', 'permission']) {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => {'outcome': outcome},
        );
        expect(
          (await access.executePhoto(
            PhysicalKind.delete,
            snapshot,
          )).outcome.name,
          outcome,
        );
      }
    },
  );
}

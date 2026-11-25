import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:phototree/backup/android_backup_adapter.dart';
import 'package:phototree/media/android_system_favorites.dart';
import 'package:phototree/media/system_favorites.dart';
import 'package:phototree/backup/backup_codec.dart';
import 'package:phototree/backup/private_snapshot.dart';
import 'package:phototree/library/favorites.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/media/physical_media.dart';
import 'package:phototree/organization/organization.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const image = Photo(id: 7, directory: 'Pictures/A/');
  const video = Photo(
    id: 7,
    directory: 'Pictures/A/',
    kind: MediaKind.video,
    durationMs: 1234,
  );
  const codec = BackupCodec();

  test(
    'native video calls carry explicit type and OEM writes remain disabled',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      final channels = [
        'io.github.tantor_d.phototree/physicalMedia',
        'io.github.tantor_d.phototree/backup',
        'io.github.tantor_d.phototree/systemFavorites',
      ];
      for (final name in channels) {
        messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
          calls.add(call);
          if (call.method == 'size') return 42;
          if (call.method == 'fingerprint') {
            return {'size': 42, 'sha256': 'a' * 64, 'filename': 'a.mp4'};
          }
          return {'outcome': 'unknown'};
        });
      }
      addTearDown(() {
        for (final name in channels) {
          messenger.setMockMethodCallHandler(MethodChannel(name), null);
        }
      });
      final physical = AndroidPhysicalMediaAccess();
      await physical.prepare([image, video], 'v');
      expect(calls.last.arguments['photos'][0].containsKey('mediaKind'), false);
      expect(calls.last.arguments['photos'][1]['mediaKind'], 'video');
      const snap = PhysicalPhotoSnapshot(
        photo: video,
        libraryVersion: 'v',
        displayName: 'a.mp4',
        size: 1,
        mimeType: 'video/mp4',
        modifiedSeconds: 0,
        generationModified: 0,
        sha256: 'a',
      );
      await physical.executePhoto(PhysicalKind.delete, snap);
      expect(calls.last.arguments['snapshot']['mediaKind'], 'video');
      await physical.reconcilePhoto(PhysicalKind.move, snap);
      expect(calls.last.arguments['snapshot']['mediaKind'], 'video');
      final backup = AndroidBackupAdapter();
      await backup.read(video, 'v');
      expect(calls.last.arguments['mediaKind'], 'video');
      await backup.size(video, 'v');
      expect(calls.last.arguments['mediaKind'], 'video');
      final count = calls.length;
      expect(
        (await AndroidSystemFavorites().set(video, 'v', true)).outcome,
        SystemFavoriteOutcome.unsupported,
      );
      expect(calls.length, count);
      await AndroidSystemFavorites(requestsSupported: true)
          .set(video, 'v', true);
      expect(calls.last.arguments['mediaKind'], 'video');
    },
  );

  test('identity JSON remains depth bounded before type decoding', () {
    final data = jsonDecode(
      File('test/fixtures/organization-backup-v1.json').readAsStringSync(),
    );
    data['favorites'][0]['identity'] = '${'[' * 1000}0${']' * 1000}';
    expect(
      () => codec.decode(utf8.encode(jsonEncode(data))),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'bounded parser',
          '备份 JSON 嵌套过深',
        ),
      ),
    );
  });

  test('same ID and timestamp retain legacy image bytes and distinct video identity', () {
    expect(image.key, 'external_primary:7');
    expect(video.key, 'external_primary:video:7');
    expect(favoriteIdentity(image, 'v'), '["external_primary",7,"v",0,0,0,0]');
    expect(
      favoriteIdentity(video, 'v'),
      '["external_primary",7,"v",0,0,0,0,"video"]',
    );
    expect(
      orderedPhotos([video, image]).map((p) => p.key),
      orderedPhotos([image, video]).map((p) => p.key),
    );
    expect(favoriteMediaKind(favoriteIdentity(image, 'v')!), MediaKind.image);
    expect(favoriteMediaKind(favoriteIdentity(video, 'v')!), MediaKind.video);
    for (final value in ['audio', '', 1, false]) {
      expect(() => mediaKindFrom(value), throwsFormatException);
    }
  });

  test('old physical snapshot round trips without schema rewrites; unknown type rejects', () {
    const snapshot = PhysicalPhotoSnapshot(
      photo: image,
      libraryVersion: 'v',
      displayName: 'a.jpg',
      size: 1,
      mimeType: 'image/jpeg',
      modifiedSeconds: 0,
      generationModified: 0,
      sha256: 'a',
    );
    final old = snapshot.toMap();
    expect(old.containsKey('mediaKind'), false);
    expect(PhysicalPhotoSnapshot.fromMap(old).toMap(), old);
    final typed = {
      ...old,
      'mediaKind': 'video',
      'durationMs': 1234,
      'mimeType': 'video/mp4',
      'displayName': 'v.mp4',
    };
    expect(PhysicalPhotoSnapshot.fromMap(typed).photo.key, video.key);
    expect(PhysicalPhotoSnapshot.fromMap(typed).toMap(), typed);
    expect(
      () => PhysicalPhotoSnapshot.fromMap({...old, 'mediaKind': 'audio'}),
      throwsFormatException,
    );
  });

  test('v3 mixed favorites preserve type and pending provenance; mismatches reject', () {
    final doc = BackupDocument(
      organization: OrganizationSnapshot([], {}),
      albums: [],
      favorites: [
        BackupFavorite(
          identity: favoriteIdentity(image, 'v')!,
          unresolvedReason: 'missing',
        ),
        BackupFavorite(
          identity: favoriteIdentity(video, 'v')!,
          mediaKind: MediaKind.video,
          source: 'system',
          pending: true,
          unresolvedReason: 'missing',
        ),
      ],
    );
    final bytes = codec.encode(doc);
    final result = codec.decode(bytes);
    expect(result.favorites.map((f) => f.mediaKind), [
      MediaKind.image,
      MediaKind.video,
    ]);
    expect(result.favorites.last.pending, true);
    expect(result.favorites.last.source, 'system');
    final data = jsonDecode(utf8.decode(bytes));
    expect(data['version'], 3);
    data['favorites'][1]['mediaKind'] = 'image';
    expect(
      () => codec.decode(utf8.encode(jsonEncode(data))),
      throwsFormatException,
    );
    data['favorites'][1]['mediaKind'] = 'audio';
    expect(
      () => codec.decode(utf8.encode(jsonEncode(data))),
      throwsFormatException,
    );
  });

  test(
    'legacy formats remain image-only and cannot smuggle video identities',
    () {
      final legacy = jsonDecode(
        File('test/fixtures/organization-backup-v1.json').readAsStringSync(),
      );
      final before = codec.decode(utf8.encode(jsonEncode(legacy)));
      expect(
        before.favorites.every((f) => f.mediaKind == MediaKind.image),
        true,
      );
      legacy['favorites'][0]['identity'] = favoriteIdentity(video, 'v');
      expect(
        () => codec.decode(utf8.encode(jsonEncode(legacy))),
        throwsFormatException,
      );
    },
  );

  test('private rollback preserves confirmed video and pending source without system writes', () {
    final identity = favoriteIdentity(video, 'v')!;
    final snapshot = PrivateSnapshot(
      OrganizationSnapshot([], {}),
      FavoriteSnapshot(
        [favoriteIdentity(image, 'v')!, favoriteIdentity(video, 'v2')!],
        [
          PendingFavorite(
            identity: identity,
            source: 'system',
            reason: 'awaiting_system_confirmation',
          ),
        ],
      ),
    );
    final recovered = PrivateSnapshot.decode(snapshot.encode());
    expect(recovered.encode(), snapshot.encode());
    expect(
      recovered.favorites.confirmed.contains(favoriteIdentity(video, 'v2')),
      true,
    );
    expect(
      favoriteMediaKind(recovered.favorites.pending.single.identity),
      MediaKind.video,
    );
    expect(recovered.favorites.pending.single.source, 'system');
  });
}

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/backup/android_backup_adapter.dart';
import 'package:phototree/backup/backup_restore.dart';
import 'package:phototree/media/media_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.tantor_d.phototree/backup');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test(
    'unknown numeric metadata retains zero identity through native boundary',
    () async {
      MethodCall? received;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            received = call;
            return {
              'size': 123,
              'sha256': 'a' * 64,
              'filename': 'unknown-date.jpg',
            };
          });
      final result = await AndroidBackupAdapter().read(
        const Photo(id: 1, directory: 'Pictures/Test/'),
        'library',
      );
      expect(received!.method, 'fingerprint');
      expect(received!.arguments, {
        'id': 1,
        'volume': 'external_primary',
        'version': 'library',
        'directory': 'Pictures/Test/',
        'addedSeconds': 0,
        'takenMs': 0,
        'width': 0,
        'height': 0,
      });
      expect(result.fingerprint.size, 123);
      expect(result.filename, 'unknown-date.jpg');
    },
  );
  test('filename lookup preserves full video identity and uses no fingerprint or write', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return '旅行长片.mp4';
        });
    const photo = Photo(
      id: 42,
      directory: 'Movies/Trip/',
      kind: MediaKind.video,
      addedSeconds: 9,
      takenMs: 10,
      width: 1920,
      height: 1080,
    );
    expect(await AndroidBackupAdapter().filename(photo, 'v'), '旅行长片.mp4');
    expect(calls.single.method, 'filename');
    expect(calls.single.arguments, {
      'id': 42,
      'mediaKind': 'video',
      'volume': 'external_primary',
      'version': 'v',
      'directory': 'Movies/Trip/',
      'addedSeconds': 9,
      'takenMs': 10,
      'width': 1920,
      'height': 1080,
    });
  });
  for (final code in ['input_too_large', 'input_read', 'input']) {
    test(
      'input $code maps platform details to a typed domain failure',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async {
              throw PlatformException(
                code: code,
                message: 'provider-path-secret',
                details: 'native stack',
              );
            });
        await expectLater(
          AndroidBackupAdapter().open(),
          throwsA(
            isA<BackupInputFailure>()
                .having(
                  (e) => e.kind,
                  'kind',
                  code == 'input_too_large'
                      ? BackupInputFailureKind.tooLarge
                      : BackupInputFailureKind.unavailable,
                )
                .having(
                  (e) => e.message.contains('provider-path-secret'),
                  'no implementation details',
                  false,
                ),
          ),
        );
      },
    );
  }
}

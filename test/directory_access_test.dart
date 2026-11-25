import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/storage/directory_access.dart';
import 'package:phototree/storage/android_directory_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('directory-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final access = AndroidDirectoryAccess(channel: channel);
  const directory = DirectoryIdentity('external_primary', 'Pictures/Test/');
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'directory boundary rejects other volumes and noncanonical segments',
    () {
      for (final path in [
        'PicturesX/Test/',
        '/Pictures/Test/',
        'Pictures/../DCIM/',
        'DCIM//Test/',
        'Pictures/./',
        'Pictures/abc\\def/',
        'Pictures/Test',
      ]) {
        expect(
          DirectoryIdentity('external_primary', path).supported,
          false,
          reason: path,
        );
      }
      expect(directory.supported, true);
      expect(
        const DirectoryIdentity('external_primary', 'DCIM/').supported,
        true,
      );
      expect(
        const DirectoryIdentity('external', 'Pictures/Test/').supported,
        false,
      );
    },
  );
  test(
    'invalid identity never invokes platform or grants capability',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => fail('unexpected platform access'),
      );
      const invalid = DirectoryIdentity(
        'external_primary',
        'Pictures/../Other/',
      );
      expect(
        (await access.inspect(invalid)).status,
        DirectoryStatus.unsupported,
      );
      expect(await access.authorize(invalid), DirectoryRequest.rejected);
    },
  );
  test(
    'every inspection rechecks; read grant never grants safe writes',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'inspect');
        calls++;
        return {
          'status': calls == 1 ? 'available' : 'revoked',
          'readable': calls == 1,
          'listable': calls == 1,
          'create': 'verified',
        };
      });
      final first = await access.inspect(directory);
      expect(first.readable, true);
      expect(first.create, SafePrimitive.unknown);
      expect(first.move, SafePrimitive.unsupported);
      expect(first.deleteEmpty, SafePrimitive.unsupported);
      expect((await access.inspect(directory)).status, DirectoryStatus.revoked);
      expect(calls, 2);
    },
  );
  test(
    'physical calls fail closed on malformed or interrupted native replies',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => 'bad-response');
      expect(
        await access.create('stale', 'Name'),
        DirectoryCreationResult.unknown,
      );
      expect(await access.verify('stale'), isFalse);
      expect((await access.readDirectory(directory)).verified, isFalse);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'lost'),
      );
      expect(await access.begin(directory), isNull);
      expect(
        await access.create('lost', 'Name'),
        DirectoryCreationResult.unknown,
      );
      expect(await access.verify('lost'), isFalse);
      await access.end('lost');
    },
  );
  test('cancel busy and process interruption are distinct', () async {
    for (final state in DirectoryRequest.values) {
      messenger.setMockMethodCallHandler(channel, (_) async => state.name);
      expect(await access.authorize(directory), state);
    }
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'busy'),
    );
    expect(await access.authorize(directory), DirectoryRequest.busy);
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'lost'),
    );
    expect(await access.authorize(directory), DirectoryRequest.interrupted);
  });
  test('malformed native response fails closed', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'status': 'bogus', 'readable': true},
    );
    final result = await access.inspect(directory);
    expect(result.status, DirectoryStatus.unavailable);
    expect(result.readable, false);
    expect(result.move, SafePrimitive.unknown);
  });
}

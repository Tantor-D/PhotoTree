import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/android_system_favorites.dart';
import 'package:phototree/media/android_media_source.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/media/system_favorites.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.tantor_d.phototree/systemFavorites');
  const photo = Photo(
    id: 17,
    directory: 'Pictures/Test/',
    addedSeconds: 5,
    takenMs: 6000,
    width: 10,
    height: 20,
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('media rows preserve true false and unknown system state', () async {
    const metadata = MethodChannel('io.github.tantor_d.phototree/metadata');
    messenger.setMockMethodCallHandler(
      metadata,
      (_) async => [
        for (final state in [true, false, null])
          {
            'id': 17,
            'directory': 'Pictures/Test/',
            'volume': 'external_primary',
            'takenMs': 6000,
            'addedSeconds': 5,
            'width': 10,
            'height': 20,
            'systemFavorite': state,
          },
      ],
    );
    try {
      final rows = await AndroidMediaSource().page(afterId: 0);
      expect(rows.map((photo) => photo.systemFavorite), [true, false, null]);
    } finally {
      messenger.setMockMethodCallHandler(metadata, null);
    }
  });

  test('unverified configurations never call native write', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return null;
    });
    final result = await AndroidSystemFavorites().set(photo, 'v1', true);
    expect(result.outcome, SystemFavoriteOutcome.unsupported);
    expect(calls, 0);
  });

  test(
    'serial request carries full stable identity without location',
    () async {
      final pending = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'set');
        expect(call.arguments, {
          'id': 17,
          'volume': 'external_primary',
          'libraryVersion': 'v1',
          'takenMs': 6000,
          'addedSeconds': 5,
          'width': 10,
          'height': 20,
          'value': true,
        });
        return pending.future;
      });
      final adapter = AndroidSystemFavorites(requestsSupported: true);
      final first = adapter.set(photo, 'v1', true);
      expect(
        (await adapter.set(photo, 'v1', false)).outcome,
        SystemFavoriteOutcome.busy,
      );
      pending.complete({'outcome': 'confirmed', 'value': true});
      final result = await first;
      expect(result.outcome, SystemFavoriteOutcome.confirmed);
      expect(result.value, true);
    },
  );

  test('cancelled, permission, stale and unknown remain distinct', () async {
    for (final outcome in SystemFavoriteOutcome.values) {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'outcome': outcome.name,
          'value': outcome == SystemFavoriteOutcome.confirmed ? true : null,
        },
      );
      expect(
        (await AndroidSystemFavorites(
          requestsSupported: true,
        ).set(photo, 'v1', true)).outcome,
        outcome,
      );
    }
  });

  test(
    'unverified success and malformed replies are unknown, never retried',
    () async {
      for (final reply in [
        null,
        {'outcome': 'confirmed'},
        {'outcome': 'confirmed', 'value': false},
        {'outcome': 'newStatus'},
        {'outcome': 'cancelled', 'value': 1},
        {
          'outcome': ['confirmed'],
          'value': true,
        },
        {1: 'confirmed', 'value': true},
      ]) {
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (_) async {
          calls++;
          return reply;
        });
        final result = await AndroidSystemFavorites(
          requestsSupported: true,
        ).set(photo, 'v1', true);
        expect(result.outcome, SystemFavoriteOutcome.unknown);
        expect(calls, 1);
      }
    },
  );

  test('non-map platform reply is unknown and releases the request', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return calls == 1 ? ['invalid reply'] : {'outcome': 'cancelled'};
    });
    final adapter = AndroidSystemFavorites(requestsSupported: true);
    expect(
      (await adapter.set(photo, 'v1', true)).outcome,
      SystemFavoriteOutcome.unknown,
    );
    expect(
      (await adapter.set(photo, 'v1', false)).outcome,
      SystemFavoriteOutcome.cancelled,
    );
    expect(calls, 2);
  });

  test(
    'channel failure releases busy state without replaying operation',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        throw PlatformException(code: 'lost');
      });
      final adapter = AndroidSystemFavorites(requestsSupported: true);
      expect(
        (await adapter.set(photo, 'v1', true)).outcome,
        SystemFavoriteOutcome.unknown,
      );
      expect(
        (await adapter.set(photo, 'v1', false)).outcome,
        SystemFavoriteOutcome.unknown,
      );
      expect(calls, 2);
    },
  );

  test(
    'pending queries are read-only and fail closed on malformed replies',
    () async {
      final adapter = AndroidSystemFavorites(requestsSupported: true);
      for (final reply in [
        true,
        false,
        null,
        'false',
        {'pending': false},
      ]) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'pending');
          expect(call.arguments, isNull);
          return reply;
        });
        expect(await adapter.hasPendingRequest(), reply is bool ? reply : null);
      }
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'lost'),
      );
      expect(await adapter.hasPendingRequest(), isNull);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await adapter.hasPendingRequest(), isNull);
    },
  );

  test('unverified pending check never calls the platform', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw StateError('unverified native query'),
    );
    expect(await AndroidSystemFavorites().hasPendingRequest(), false);
  });

  test('native pending replies require unknown and an exact boolean', () async {
    final adapter = AndroidSystemFavorites(requestsSupported: true);
    for (final reply in [
      {'outcome': 'unknown', 'pending': true},
      {'outcome': 'unknown', 'pending': 'true'},
      {'outcome': 'confirmed', 'value': true, 'pending': true},
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => reply);
      final result = await adapter.set(photo, 'v1', true);
      expect(result.outcome, SystemFavoriteOutcome.unknown);
      expect(
        result.pending,
        reply['pending'] == true && reply['outcome'] == 'unknown' ? true : null,
      );
    }
  });

  testWidgets('stalled pending query is bounded without launching a write', (
    tester,
  ) async {
    final reply = Completer<Object?>();
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) {
      expect(call.method, 'pending');
      calls++;
      return reply.future;
    });
    final pending = AndroidSystemFavorites(requestsSupported: true)
        .hasPendingRequest();
    await tester.pump(const Duration(seconds: 3));
    expect(await pending, isNull);
    expect(calls, 1);
    reply.complete(false);
    await tester.pump();
  });

  test(
    'missing plugin is unsupported and missing identity does not write',
    () async {
      final adapter = AndroidSystemFavorites(requestsSupported: true);
      expect(
        (await adapter.set(photo, '', true)).outcome,
        SystemFavoriteOutcome.stale,
      );
      expect(
        (await adapter.set(photo, 'v1', true)).outcome,
        SystemFavoriteOutcome.unsupported,
      );
      expect(photo.systemFavorite, isNull);
    },
  );
}

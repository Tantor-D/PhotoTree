import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/backup/backup_codec.dart';
import 'package:phototree/organization/organization.dart';

void main() {
  const codec = BackupCodec();
  final golden = File('test/fixtures/organization-backup-v1.json')
      .readAsBytesSync();
  Map<String, dynamic> data() =>
      jsonDecode(utf8.decode(golden)) as Map<String, dynamic>;
  BackupDocument decode(Map<String, dynamic> value) =>
      codec.decode(utf8.encode(jsonEncode(value)));
  void rejects(void Function(Map<String, dynamic>) edit) {
    final value = data();
    edit(value);
    expect(() => decode(value), throwsFormatException);
  }

  test('golden preserves five levels, hidden slots, descriptions and all favorites', () {
    final document = codec.decode(golden);
    expect(document.organization.path('f5'), [
      'root',
      'f1',
      'f2',
      'f3',
      'f4',
      'f5',
    ]);
    expect(document.organization.folderOrders['root'], ['empty', 'f1']);
    expect(document.organization.albumOrders['f5'], ['a2', 'a1']);
    expect(document.organization.albumOrders['root'], ['a3']);
    expect(document.organization.albumOrders['empty'], isEmpty);
    expect(document.organization.albumOrders.containsKey('f2'), isFalse);
    expect(document.albums.last.pending, isTrue);
    expect(document.favorites.length, 2);
    expect(document.unresolvedCount, 1);
    final upgraded = jsonDecode(utf8.decode(codec.encode(document)));
    expect(upgraded['version'], 3);
    expect(upgraded['format'], 'phototree-organization-backup');
    expect(upgraded['systemSnapshotComplete'], false);
    expect(
      codec.decode(codec.encode(document)).favorites.first.source,
      'legacy',
    );
    expect(() => document.albums.clear(), throwsUnsupportedError);
    expect(() => document.favorites.clear(), throwsUnsupportedError);
    expect(
      () => document.organization.albumOrders['root']!.clear(),
      throwsUnsupportedError,
    );
  });

  test('v2 sources and completeness round trip; malformed sources reject', () {
    final v2 = jsonDecode(
      utf8.decode(codec.encode(codec.decode(golden))),
    ) as Map<String, dynamic>;
    v2['version'] = 2;
    for (final f in v2['favorites']) {
      f.remove('mediaKind');
    }
    v2['systemSnapshotComplete'] = true;
    v2['favorites'][0]['source'] = 'both';
    v2['favorites'][1]['source'] = 'system';
    v2['favorites'][1]['systemFavorite'] = false;
    v2['favorites'][1]['pending'] = true;
    final result = decode(v2);
    expect(result.systemSnapshotComplete, true);
    expect(result.favorites.map((f) => f.source), ['both', 'system']);
    expect(result.favorites.first.systemFavorite, isNull);
    expect(result.favorites.last.systemFavorite, false);
    expect(result.favorites.last.pending, true);
    v2['favorites'][1]['systemFavorite'] = 'unknown';
    expect(() => decode(v2), throwsFormatException);
    v2['favorites'][1]['systemFavorite'] = null;
    v2['favorites'][1]['pending'] = 'true';
    expect(() => decode(v2), throwsFormatException);
    v2['favorites'][1]['pending'] = true;
    v2['favorites'][0]['source'] = 'automatic_write';
    expect(() => decode(v2), throwsFormatException);
    v2['favorites'][0]['source'] = 'legacy';
    v2['systemSnapshotComplete'] = 'true';
    expect(() => decode(v2), throwsFormatException);
    v2['systemSnapshotComplete'] = false;
    v2['favorites'][1]['identity'] = v2['favorites'][0]['identity'];
    expect(() => decode(v2), throwsFormatException);
  });

  test('truncated documents and malformed UTF-8 rejected', () {
    for (final cut in [0, 1, golden.length ~/ 2, golden.length - 3]) {
      expect(() => codec.decode(golden.sublist(0, cut)), throwsFormatException);
    }
    expect(() => codec.decode([0xc3, 0x28]), throwsFormatException);
    expect(() => codec.decode([...golden, 0xff]), throwsFormatException);
  });

  test('format, integer version, unknown and missing fields rejected', () {
    rejects((v) => v['version'] = 2);
    rejects((v) => v['version'] = 1.0);
    rejects((v) => v['format'] = 'other');
    rejects((v) => v['photoBytes'] = 'no');
    rejects((v) => v.remove('favorites'));
    rejects((v) => v['folders'][0]['extra'] = true);
    rejects((v) => v['albums'][0]['pending'] = 'true');
  });

  test('duplicate JSON keys are rejected before conversion, including escaped spelling', () {
    final text = utf8.decode(golden);
    expect(
      () => codec.decode(
        utf8.encode(
          text.replaceFirst('"version": 1', '"version": 1, "version": 1'),
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => codec.decode(
        utf8.encode(
          text.replaceFirst('"version": 1', r'"version": 1, "versi\u006fn": 1'),
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => codec.decode(
        utf8.encode(
          text.replaceFirst('"size": 1234', '"size": 1234, "size": 1234'),
        ),
      ),
      throwsFormatException,
    );
  });

  test(
    'duplicate folder album placement identity and order records rejected',
    () {
      for (final field in [
        'folders',
        'albums',
        'placements',
        'favorites',
        'folderOrders',
        'albumOrders',
      ]) {
        rejects((v) => v[field].add(v[field][0]));
      }
      rejects((v) => v['folderOrders'][0]['ids'].add('f1'));
      rejects((v) => v['albumOrders'][0]['ids'].add('a3'));
    },
  );

  test('orphan cycles reserved root and sibling name conflicts rejected', () {
    rejects((v) => v['folders'][0]['parent'] = 'missing');
    rejects((v) => v['folders'][0]['parent'] = 'f5');
    rejects((v) => v['folders'][0]['id'] = 'root');
    rejects((v) => v['folders'][5]['name'] = '旅行');
    rejects((v) => v['folders'][0]['name'] = ' name ');
    rejects((v) => v['folders'][0]['name'] = 'bad\nname');
  });

  test(
    'missing descriptions, cross-parent orders, incomplete orders rejected',
    () {
      rejects((v) => v['placements'][0]['albumId'] = 'missing');
      rejects((v) => v['placements'][0]['parent'] = 'root');
      rejects((v) => v['placements'][0]['parent'] = 'missing');
      rejects((v) => v['albumOrders'][0]['ids'] = ['missing']);
      rejects((v) => v['albumOrders'][0]['ids'] = ['a1']);
      rejects((v) => v['albumOrders'][1]['ids'] = ['a1']);
      rejects((v) => v['folderOrders'][0]['ids'] = ['f1']);
      rejects((v) => v['folderOrders'][0]['ids'] = ['f2', 'empty']);
      rejects((v) => v['favorites'][0]['albumId'] = 'missing');
    },
  );

  test(
    'identities validate complete original tuple and typed nonnegative values',
    () {
      for (final identity in [
        '[]',
        '{}',
        '["v",1,"l",0,0,0]',
        '["",1,"l",0,0,0,0]',
        '["v",1,"",0,0,0,0]',
        '["v","1","l",0,0,0,0]',
        '["v",1,"l",0,-1,0,0]',
        '["v",1,"l",0,0,0,0.0]',
      ]) {
        rejects((v) => v['favorites'][0]['identity'] = identity);
      }
    },
  );

  test(
    'fingerprints require exact lowercase SHA256 and integer byte count',
    () {
      for (final hash in ['', 'abc', 'A' * 64, 'g' * 64, 'a' * 65]) {
        rejects((v) => v['favorites'][0]['fingerprint']['sha256'] = hash);
      }
      rejects((v) => v['favorites'][0]['fingerprint']['size'] = -1);
      rejects((v) => v['favorites'][0]['fingerprint']['size'] = 1.5);
      rejects((v) => v['favorites'][0]['unresolvedReason'] = 'also-unresolved');
      rejects((v) => v['favorites'][1]['unresolvedReason'] = null);
      rejects((v) => v['favorites'][1]['unresolvedReason'] = '');
    },
  );

  test('nesting rejected before JSON decoder recursion', () {
    expect(
      () => codec.decode(utf8.encode('${'[' * 10000}0${']' * 10000}')),
      throwsFormatException,
    );
    rejects(
      (v) => v['favorites'][0]['identity'] = '${'[' * 10000}0${']' * 10000}',
    );
  });

  test('legal deep trees roundtrip without an extra domain depth limit', () {
    Map<String, dynamic> tree(int depth) => {
      'format': BackupCodec.format,
      'version': 1,
      'folders': [
        for (var i = 0; i < depth; i++)
          {
            'id': 'f$i',
            'parent': i == 0 ? 'root' : 'f${i - 1}',
            'name': 'folder',
          },
      ],
      'albums': [],
      'placements': [],
      'favorites': [],
      'folderOrders': [],
      'albumOrders': [],
    };
    expect(decode(tree(256)).organization.path('f255').length, 257);
    final watch = Stopwatch()..start();
    final deep = decode(tree(50000));
    final restored = codec.decode(codec.encode(deep));
    expect(restored.organization.folders.length, 50000);
    expect(restored.organization.folders['f49999']!.parent, 'f49998');
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test(
    'exact byte boundary accepted; one byte over rejected before parsing',
    () {
      final bytes = Uint8List(BackupCodec.maxBytes)
        ..fillRange(0, BackupCodec.maxBytes, 32);
      bytes.setRange(0, golden.length, golden);
      expect(codec.decode(bytes).favorites.length, 2);
      expect(
        () => codec.decode(Uint8List(BackupCodec.maxBytes + 1)),
        throwsFormatException,
      );
    },
  );

  test('records include orders and every nested reference', () {
    final count = (BackupCodec.maxRecords - 2) ~/ 2;
    final value = {
      'format': BackupCodec.format,
      'version': 1,
      'folders': [],
      'albums': [
        for (var i = 0; i < count; i++)
          {
            'id': 'a$i',
            'sourceKey': null,
            'name': null,
            'directory': null,
            'pending': false,
          },
      ],
      'placements': [],
      'favorites': [],
      'folderOrders': [
        {'parent': 'root', 'ids': []},
      ],
      'albumOrders': [
        {
          'parent': 'root',
          'ids': [for (var i = 0; i < count; i++) 'a$i'],
        },
      ],
    };
    expect(decode(value).albums.length, count);
    (value['albums'] as List).add({
      'id': 'last',
      'sourceKey': null,
      'name': null,
      'directory': null,
      'pending': false,
    });
    expect(() => decode(value), throwsFormatException);
  });

  test('near-limit many-parent document validates within bounded time', () {
    const count = 49999;
    final value = {
      'format': BackupCodec.format,
      'version': 1,
      'folders': [
        for (var i = 0; i < count; i++)
          {'id': 'f$i', 'parent': 'root', 'name': 'Folder $i'},
      ],
      'albums': [],
      'placements': [],
      'favorites': [],
      'folderOrders': [
        for (var i = 0; i < count; i++) {'parent': 'f$i', 'ids': []},
      ],
      'albumOrders': [],
    };
    final watch = Stopwatch()..start();
    expect(decode(value).organization.folders.length, count);
    watch.stop();
    // This adversarial input previously caused approximately 2.5 billion scans.
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test(
    'private tree validation memoizes very deep chains and rejects cycles',
    () {
      const count = 50000;
      final watch = Stopwatch()..start();
      final snapshot = OrganizationSnapshot([
        for (var i = 0; i < count; i++)
          AlbumFolder('f$i', i == 0 ? rootFolder : 'f${i - 1}', 'Folder'),
      ], {});
      expect(snapshot.folders.length, count);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      expect(
        () => OrganizationSnapshot([
          for (var i = 0; i < count; i++)
            AlbumFolder(
              'f$i',
              i == 0 ? 'f${count - 1}' : 'f${i - 1}',
              'Folder',
            ),
        ], {}),
        throwsA(isA<OrganizationError>()),
      );
    },
  );

  test(
    'encode shares domain validation and refuses unreferenced data corruption',
    () {
      expect(
        () => codec.encode(
          BackupDocument(
            organization: OrganizationSnapshot([], {'missing': 'root'}),
            albums: [],
            favorites: [],
          ),
        ),
        throwsA(isA<OrganizationError>()),
      );
      final valid = codec.decode(golden);
      expect(
        () => codec.encode(
          BackupDocument(
            organization: valid.organization,
            albums: valid.albums,
            favorites: [...valid.favorites, valid.favorites.first],
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => codec.encode(
          BackupDocument(
            organization: valid.organization,
            albums: valid.albums.take(1),
            favorites: valid.favorites,
          ),
        ),
        throwsFormatException,
      );
    },
  );
}

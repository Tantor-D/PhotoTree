import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/storage/sidebar_preferences.dart';

void main() {
  late Directory folder;
  late SidebarPreferences preferences;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('phototree-sidebar-test-');
    preferences = SidebarPreferences(directory: () async => folder);
  });
  tearDown(() async => folder.delete(recursive: true));

  test('defaults and saved opacity survive a new store instance', () async {
    expect(await preferences.readOpacity(), isNull);
    for (final value in [70, 86, 90, 100, null]) {
      await preferences.writeOpacity(value);
      final reloaded = SidebarPreferences(directory: () async => folder);
      expect(await reloaded.readOpacity(), value);
    }
    expect(
      await File('${folder.path}/${SidebarPreferences.filename}.pending')
          .exists(),
      isFalse,
    );
  });

  test('legacy values are readable but cannot be newly written', () async {
    final file = File('${folder.path}/${SidebarPreferences.filename}');
    for (final value in [40, 55, 69]) {
      await file.writeAsString('{"version":1,"opacity":$value}');
      expect(await preferences.readOpacity(), value);
      await expectLater(preferences.writeOpacity(value), throwsRangeError);
      expect(await preferences.readOpacity(), value);
      await preferences.writeOpacity(70);
      expect(await preferences.readOpacity(), 70);
    }
  });

  test(
    'malformed content is retained, including when user saves a new choice',
    () async {
      final file = File('${folder.path}/${SidebarPreferences.filename}');
      const invalid = '{unfinished preference';
      await file.writeAsString(invalid);
      await expectLater(preferences.readOpacity(), throwsFormatException);
      expect(await file.readAsString(), invalid);
      await preferences.writeOpacity(72);
      expect(await preferences.readOpacity(), 72);
      final backups = await folder
          .list()
          .where((entry) => entry.path.contains('.invalid-'))
          .toList();
      expect(backups, hasLength(1));
      expect(await File(backups.single.path).readAsString(), invalid);
    },
  );

  test('invalid schema and out of range saved settings are rejected', () async {
    final file = File('${folder.path}/${SidebarPreferences.filename}');
    for (final content in [
      '{"version":2,"opacity":80}',
      '{"version":1,"opacity":39}',
      '{"version":1,"opacity":101}',
      '{"version":1,"opacity":86.5}',
      '{"version":1}',
    ]) {
      await file.writeAsString(content);
      await expectLater(preferences.readOpacity(), throwsFormatException);
      expect(await file.readAsString(), content);
    }
  });

  test(
    'invalid UTF-8 is preserved and an explicit new choice can be saved',
    () async {
      final file = File('${folder.path}/${SidebarPreferences.filename}');
      final bytes = [0xFF, 0xFE];
      await file.writeAsBytes(bytes);
      await expectLater(preferences.readOpacity(), throwsFormatException);
      expect(await file.readAsBytes(), bytes);
      await preferences.writeOpacity(70);
      expect(await preferences.readOpacity(), 70);
      final backup =
          (await folder
                  .list()
                  .where((entry) => entry.path.contains('.invalid-'))
                  .toList())
              .single;
      expect(await File(backup.path).readAsBytes(), bytes);
    },
  );

  test(
    'failed replacement preserves the last saved value and can retry',
    () async {
      await preferences.writeOpacity(80);
      final blocker = Directory(
        '${folder.path}/${SidebarPreferences.filename}.pending',
      );
      await blocker.create();
      await expectLater(
        preferences.writeOpacity(95),
        throwsA(isA<FileSystemException>()),
      );
      expect(await preferences.readOpacity(), 80);
      await blocker.delete();
      await preferences.writeOpacity(95);
      expect(await preferences.readOpacity(), 95);
    },
  );

  test(
    'non-file paths and invalid inputs never replace existing data',
    () async {
      final blocker = Directory(
        '${folder.path}/${SidebarPreferences.filename}',
      );
      await blocker.create();
      final preserved = File('${blocker.path}/unrelated.txt');
      await preserved.writeAsString('preserve');
      await expectLater(
        preferences.readOpacity(),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        preferences.writeOpacity(86),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(preferences.writeOpacity(0), throwsRangeError);
      expect(await preserved.readAsString(), 'preserve');
    },
  );
}

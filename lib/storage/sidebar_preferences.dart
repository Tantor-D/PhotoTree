import 'dart:convert';
import 'dart:io';

/// One UI preference, separate from organization, favorites and operation logs.
/// The caller owns the session value and serializes writes (slider release only).
class SidebarPreferences {
  const SidebarPreferences({required this.directory});

  final Future<Directory> Function() directory;
  static const filename = 'sidebar-appearance.json';

  int? _decode(String text) {
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        !value.containsKey('opacity') ||
        value.keys.any((key) => key != 'version' && key != 'opacity')) {
      throw const FormatException('Unsupported sidebar preference format');
    }
    final opacity = value['opacity'];
    if (opacity != null && (opacity is! int || opacity < 40 || opacity > 100)) {
      throw const FormatException('Invalid sidebar opacity');
    }
    return opacity as int?;
  }

  Future<int?> _read(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Preference path is not a regular file',
        file.path,
      );
    }
    if (await file.length() > 1024) {
      throw const FormatException('Sidebar preference is too large');
    }
    // Decode separately so malformed UTF-8 remains a FormatException rather
    // than being wrapped as an I/O error by File.readAsString.
    return _decode(utf8.decode(await file.readAsBytes()));
  }

  Future<int?> readOpacity() async {
    final folder = await directory();
    return _read(File('${folder.path}/$filename'));
  }

  Future<void> writeOpacity(int? opacity) async {
    if (opacity != null && (opacity < 70 || opacity > 100)) {
      throw RangeError.range(opacity, 70, 100, 'opacity');
    }
    final folder = await directory();
    await folder.create(recursive: true);
    final file = File('${folder.path}/$filename');
    try {
      await _read(file);
    } on FormatException {
      // A deliberate new selection may replace an unreadable preference, but
      // retain the exact old bytes for investigation instead of erasing them.
      var suffix = DateTime.now().microsecondsSinceEpoch;
      var backup = '${file.path}.invalid-$suffix';
      while (await FileSystemEntity.type(backup) !=
          FileSystemEntityType.notFound) {
        backup = '${file.path}.invalid-${++suffix}';
      }
      await file.copy(backup);
    }
    final pending = File('${file.path}.pending');
    await pending.writeAsString(
      jsonEncode({'version': 1, 'opacity': opacity}),
      flush: true,
    );
    // Keep the replacement beside the destination; a failed write leaves the
    // previously saved value intact. Report rename failures to the caller too.
    await pending.rename(file.path);
  }
}

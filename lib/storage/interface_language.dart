import 'dart:io';

enum InterfaceLanguage {
  system('跟随系统 / System default'),
  chinese('简体中文'),
  english('English');

  const InterfaceLanguage(this.label);
  final String label;
}

class InterfaceLanguageStore {
  const InterfaceLanguageStore(this.directory);
  final Future<Directory> Function() directory;

  Future<InterfaceLanguage> read() async {
    final folder = await directory();
    final file = File('${folder.path}/interface-language');
    if (await FileSystemEntity.type(file.path) ==
        FileSystemEntityType.notFound) {
      return InterfaceLanguage.system;
    }
    return InterfaceLanguage.values.byName(await file.readAsString());
  }

  Future<void> write(InterfaceLanguage language) async {
    final folder = await directory();
    await folder.create(recursive: true);
    final file = File('${folder.path}/interface-language.pending');
    await file.writeAsString(language.name, flush: true);
    await file.rename('${folder.path}/interface-language');
  }
}

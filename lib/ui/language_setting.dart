import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'visual_style.dart';
import '../storage/interface_language.dart';
import 'interface_strings.dart';

class LanguageScope extends InheritedWidget {
  const LanguageScope({
    super.key,
    required super.child,
    required this.selection,
    required this.error,
    required this.select,
  });
  final InterfaceLanguage selection;
  final String? error;
  final ValueChanged<InterfaceLanguage> select;

  @override
  bool updateShouldNotify(LanguageScope old) =>
      selection != old.selection || error != old.error;
}

class LanguageSetting extends StatelessWidget {
  const LanguageSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LanguageScope>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.language),
          title: const Text('语言 / Language'),
          subtitle: Text((scope?.selection ?? InterfaceLanguage.system).label),
          onTap: scope == null
              ? null
              : () async {
                  final choice = await showDialog<InterfaceLanguage>(
                    context: context,
                    builder: (dialog) => SimpleDialog(
                      title: const Text('语言 / Language'),
                      children: [
                        for (final language in InterfaceLanguage.values)
                          ListTile(
                            title: Text(language.label),
                            selected: language == scope.selection,
                            trailing: language == scope.selection
                                ? const Icon(Icons.check)
                                : null,
                            onTap: () => Navigator.pop(dialog, language),
                          ),
                      ],
                    ),
                  );
                  if (choice != null && context.mounted) scope.select(choice);
                },
        ),
        if (scope?.error case final error?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Semantics(liveRegion: true, child: Text(context.tr(error))),
          ),
      ],
    );
  }
}

class InterfaceLanguageApp extends StatefulWidget {
  const InterfaceLanguageApp({
    super.key,
    required this.store,
    required this.home,
  });
  final InterfaceLanguageStore store;
  final Widget home;
  @override
  State<InterfaceLanguageApp> createState() => _InterfaceLanguageAppState();
}

class _InterfaceLanguageAppState extends State<InterfaceLanguageApp> {
  late final Future<void> languageLoaded;
  Future<void> languageWrites = Future.value();
  InterfaceLanguage selection = InterfaceLanguage.system;
  String? languageError;

  Future<void> loadLanguage() async {
    try {
      final saved = await widget.store.read();
      if (mounted) setState(() => selection = saved);
    } catch (_) {
      if (mounted) setState(() => languageError = '无法读取语言设置，正在跟随系统。');
    }
  }

  void selectLanguage(InterfaceLanguage value) {
    languageWrites = languageWrites.then((_) async {
      await languageLoaded;
      try {
        await widget.store.write(value);
        if (mounted) {
          setState(() {
            selection = value;
            languageError = null;
          });
        }
      } catch (_) {
        if (mounted) setState(() => languageError = '语言设置保存失败，已保留上次选择。');
      }
    });
  }

  @override
  void initState() {
    super.initState();
    languageLoaded = loadLanguage();
  }

  @override
  Widget build(BuildContext context) {
    return LanguageScope(
      selection: selection,
      error: languageError,
      select: selectLanguage,
      child: MaterialApp(
        localizationsDelegates: const [
          InterfaceStrings(),
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh'), Locale('en')],
        locale: switch (selection) {
          InterfaceLanguage.system => null,
          InterfaceLanguage.chinese => const Locale('zh'),
          InterfaceLanguage.english => const Locale('en'),
        },
        localeListResolutionCallback: (locales, _) =>
            Locale(locales?.firstOrNull?.languageCode == 'en' ? 'en' : 'zh'),
        title: 'PhotoTree',
        debugShowCheckedModeBanner: false,
        theme: photoTreeTheme(Brightness.light),
        darkTheme: photoTreeTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        builder: photoTreeAppBuilder,
        home: widget.home,
      ),
    );
  }
}

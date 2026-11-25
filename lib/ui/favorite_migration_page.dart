import 'interface_strings.dart';

import 'package:flutter/material.dart';

import 'visual_style.dart';

import 'dialog_action_bar.dart';

import '../library/favorites.dart';
import '../media/browser.dart';
import '../media/system_favorites.dart';
import 'photo_grid.dart';

String favoriteResultText(BuildContext context, SystemFavoriteOutcome result) =>
    switch (result) {
      SystemFavoriteOutcome.confirmed => context.tr('已回读确认'),
      SystemFavoriteOutcome.cancelled => context.tr('已取消，未确认更改'),
      SystemFavoriteOutcome.unsupported => context.tr('系统互通尚未验证或不支持'),
      SystemFavoriteOutcome.permission => context.tr('照片访问权限不足'),
      SystemFavoriteOutcome.stale => context.tr('照片身份已变化，请刷新'),
      SystemFavoriteOutcome.failed => context.tr('操作失败，请重试'),
      SystemFavoriteOutcome.unknown => context.tr('结果待核验，不会自动重试'),
      SystemFavoriteOutcome.busy => context.tr('另一项操作正在进行'),
    };

class FavoriteMigrationPage extends StatefulWidget {
  const FavoriteMigrationPage({super.key, required this.favorites});
  final Favorites favorites;
  @override
  State<FavoriteMigrationPage> createState() => _FavoriteMigrationPageState();
}

class _FavoriteMigrationPageState extends State<FavoriteMigrationPage> {
  final _selected = <String>{};
  bool _applying = false;
  String? _message;

  Future<void> _apply() async {
    final favorites = widget.favorites;
    final selected = Set<String>.of(_selected);
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => PhotoTreeConfirmation(
        title: Text(context.tr('添加 {0} 项到系统收藏？', [selected.length])),
        content: Text(
          context.tr('只添加所选照片，不取消已有系统收藏。原应用收藏记录保留。') +
              context.tr('系统将逐项处理，可能显示确认提示；取消或结果不确定时停止后续项目。'),
        ),
        dismissLabel: context.tr('取消'),
        onDismiss: () => Navigator.pop(context, false),
        actionLabel: context.tr('继续'),
        onAction: () => Navigator.pop(context, true),
      ),
    );
    if (!mounted || approved != true) return;
    setState(() {
      _applying = true;
      _message = null;
    });
    try {
      await favorites.migrateSelected(selected);
      if (mounted) {
        setState(() {
          _message = '本次处理结束，请查看逐项结果；未完成项目仍保留。';
          _selected.clear();
        });
      }
    } catch (_) {
      if (mounted) setState(() => _message = '处理未完成；原记录保留，请核对后重试。');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final favorites = widget.favorites;
    final browser = favorites.browser;
    return ListenableBuilder(
      listenable: Listenable.merge([favorites, browser]),
      builder: (context, _) {
        final candidates = favorites.migrationCandidates;
        final visibleIds = candidates
            .map((p) => favoriteIdentity(p, browser.libraryVersion))
            .toSet();
        final selectedCount = _selected.where(visibleIds.contains).length;
        final ready =
            favorites.systemMode &&
            favorites.phase == FavoritePhase.ready &&
            browser.phase == BrowsePhase.ready &&
            !favorites.held &&
            !favorites.systemRequestPending &&
            !_applying;
        return PopScope<void>(
          canPop: !_applying,
          child: Scaffold(
            appBar: photoTreePageBar(context, title: context.tr('原应用与恢复的收藏')),
            body: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      favorites.systemMode
                          ? context.tr('旧收藏和恢复记录不会自动写入系统。请选择要添加的照片；不取消系统已有收藏。')
                          : context.tr('系统相册互通尚未验证。现有应用内收藏保留，暂不能迁移到系统。'),
                    ),
                  ),
                  if (favorites.systemRequestPending)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          Text(
                            context.tr(
                              '系统收藏请求尚未确认结束，相关操作已暂停。核对只读取请求状态，不会再次提交收藏。',
                            ),
                          ),
                          TextButton(
                            onPressed: favorites.checkingSystemRequest
                                ? null
                                : favorites.reconcileSystemRequest,
                            child: Text(
                              favorites.checkingSystemRequest
                                  ? context.tr('正在核对…')
                                  : context.tr('核对未决收藏请求'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (favorites.migrationUnavailableCount > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        context.tr('{0} 项暂不可访问或尚未匹配；记录保留。', [
                          favorites.migrationUnavailableCount,
                        ]),
                      ),
                    ),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(context.domainText(_message!)),
                    ),
                  if (_applying) const LinearProgressIndicator(),
                  Expanded(
                    child: candidates.isEmpty
                        ? Center(child: Text(context.tr('当前没有可选择的旧收藏或恢复记录')))
                        : ListView.builder(
                            itemCount: candidates.length,
                            itemBuilder: (context, index) {
                              final photo = candidates[index];
                              final identity = favoriteIdentity(
                                photo,
                                browser.libraryVersion,
                              )!;
                              final outcome = favorites.resultFor(photo);
                              final savedOutcome = favorites
                                  .snapshot
                                  .migrationOutcomes[identity];
                              return CheckboxListTile(
                                key: ValueKey(identity),
                                value: _selected.contains(identity),
                                onChanged: ready
                                    ? (checked) => setState(() {
                                        checked == true
                                            ? _selected.add(identity)
                                            : _selected.remove(identity);
                                      })
                                    : null,
                                secondary: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: PhotoTile(
                                    key: ValueKey(
                                      '${browser.imageGeneration}:${photo.key}',
                                    ),
                                    browser: browser,
                                    photo: photo,
                                    size: 48,
                                  ),
                                ),
                                title: Text(context.tr('照片 {0}', [photo.id])),
                                subtitle: Text(
                                  '${switch (photo.systemFavorite) {
                                    true => context.tr('当前已是系统收藏'),
                                    false => context.tr('当前未收藏'),
                                    null => context.tr('当前系统状态未知'),
                                  }}${outcome != null
                                      ? context.tr('\n上次操作：{0}', [favoriteResultText(context, outcome)])
                                      : savedOutcome != null
                                      ? context.tr('\n上次操作：{0}', [favoriteResultText(context, SystemFavoriteOutcome.values.byName(savedOutcome))])
                                      : ''}',
                                ),
                              );
                            },
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton(
                      onPressed:
                          ready &&
                              selectedCount > 0 &&
                              selectedCount == _selected.length
                          ? _apply
                          : null,
                      child: Text(
                        _applying
                            ? context.tr('正在逐项处理…')
                            : context.tr('将所选 {0} 项添加到系统收藏', [selectedCount]),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

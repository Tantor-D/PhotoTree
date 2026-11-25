import 'interface_strings.dart';

import 'package:flutter/material.dart';

import 'visual_style.dart';
import 'backup_widgets.dart';

import 'dialog_action_bar.dart';

import 'physical_album_page.dart';

import '../backup/backup_codec.dart';
import '../backup/backup_restore.dart';
import '../backup/backup_export.dart';
import '../library/favorites.dart';
import '../media/media_source.dart';
import '../media/browser.dart';
import '../organization/organization.dart';

enum RestoreIntent { file, pending, rollback }

enum _Step { select, summary, albums, favorites, preview, result }

class RestorePage extends StatefulWidget {
  const RestorePage({
    super.key,
    required this.restore,
    this.intent = RestoreIntent.file,
  });
  final RestoreIntent intent;
  final BackupRestore restore;
  @override
  State<RestorePage> createState() => _RestorePageState();
}

class _RestorePageState extends State<RestorePage> {
  BackupRestore get r => widget.restore;
  BackupDocument? _document;
  RestorePreview? _preview;
  Map<String, String?> _mappings = {};
  final Set<String> _confirmed = {};
  final Map<String, String> _manual = {};
  bool _pending = false, _working = false;
  String? _message, _invalidDetail;
  _Step _step = _Step.select;
  RestorePreview? _result;
  bool _changed = false, _committing = false;
  String _albumFilter = '全部';
  final Map<String, Future<String?>> _names = {};
  Future<String?> _filename(Photo photo) {
    final version = r.browser.libraryVersion;
    if (version == null) return Future.value(null);
    final key = '${r.browser.generation}:${favoriteIdentity(photo, version)}';
    return _names.putIfAbsent(
      key,
      () => r.media.filename(photo, version).catchError((Object _) => null),
    );
  }

  int _generation = -1;
  bool get _busy => _working || r.busy;
  @override
  void initState() {
    super.initState();
    _generation = r.browser.generation;
    r.addListener(_updated);
    r.browser.addListener(_mediaChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || r.blocked) return;
      if (widget.intent == RestoreIntent.pending) {
        _setDocument(r.pendingDocument(), true);
      }
      if (widget.intent == RestoreIntent.rollback) _rollback();
    });
  }

  void _updated() {
    if (mounted) setState(() {});
  }

  void _mediaChanged() {
    if (!mounted || _generation == r.browser.generation) return;
    _generation = r.browser.generation;
    setState(() {
      if (_preview?.rollback == true) {
        _step = _Step.select;
        _message = '媒体访问范围已变化，请返回首页重新查看回滚预览。';
      }
      _preview = null;
      _names.clear();
      if (_document != null && _step != _Step.summary) {
        _step = _Step.albums;
      }
      _manual.clear();
      _confirmed.clear();
      _mappings = {
        for (final a in _document?.albums ?? <BackupAlbum>[]) a.id: null,
      };
      if (_document != null) _message = '媒体访问范围已变化，请重新确认目录和媒体。';
    });
  }

  @override
  void dispose() {
    r.removeListener(_updated);
    r.browser.removeListener(_mediaChanged);
    r.cancelPreview();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() task) async {
    if (_busy) return;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      await task();
    } on BackupMediaRefreshing {
      if (mounted) setState(() => _message = '媒体列表正在刷新，请稍后重试。');
    } on BackupInputFailure catch (error) {
      if (mounted) setState(() => _message = error.message);
    } on RestoreProblem catch (error) {
      if (mounted) {
        setState(() => _message = r.blocked ? r.status : error.message);
      }
    } on FormatException catch (error) {
      // The codec's validation messages are authored for users. Parser/UTF-8
      // internals are replaced with a plain explanation rather than dumped.
      if (mounted) {
        setState(() {
          _invalidDetail = RegExp(r'^[\u4e00-\u9fff]').hasMatch(error.message)
              ? error.message
              : '文件内容不完整或格式无效';
          _message = '备份无效：{0}。私有数据未改变。';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = r.blocked ? r.status : '操作未完成，请稍后重试。');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _setDocument(BackupDocument d, bool pending) {
    setState(() {
      _document = d;
      _pending = pending;
      _step = pending ? _Step.albums : _Step.summary;
      _result = null;
      _preview = null;
      _mappings = r.proposals(d);
      _confirmed.clear();
      _manual.clear();
      if (pending) {
        for (final a in d.albums) {
          if (!a.pending &&
              r.organization.restoreAlbums.any((now) => now.key == a.id)) {
            _mappings[a.id] = a.id;
          }
        }
      }
      _generation = r.browser.generation;
    });
  }

  Future<void> _choose() => _run(() async {
    final d = await r.choose();
    if (!mounted) return;
    if (d == null) {
      setState(() => _message = '已取消选择备份，私有数据未改变。');
      return;
    }
    await r.browser.refresh();
    if (mounted) _setDocument(d, false);
  });
  Future<void> _mapping(BackupAlbum album) async {
    final albums = r.organization.restoreAlbums;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        insetPadding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 400),
        titleTextStyle: Theme.of(context).textTheme.titleLarge,
        title: Text(
          context.tr('关联目录：{0}', [album.name ?? album.directory ?? album.id]),
        ),
        children: [
          _details(context.tr('原相册位置'), [
            (context.tr('名称'), _albumName(album)),
            (
              context.tr('原目录'),
              album.sourceKey ?? album.directory ?? context.tr('未知'),
            ),
          ]),
          SimpleDialogOption(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            onPressed: () => Navigator.pop(context, ''),
            child: Text(context.tr('暂不关联（保留待关联记录）')),
          ),
          if (r.organization.physicalCreationAvailable)
            SimpleDialogOption(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              onPressed: () => Navigator.pop(context, '@select-existing'),
              child: Text(context.tr('选择已存在的真实空目录…')),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: BackupRecords<Album>(
              items: albums,
              label: (a) => '${context.albumName(a)} ${a.key}',
              searchLabel: context.tr('搜索目标相册或路径'),
              builder: (a) => ListTile(
                title: Text(context.albumName(a)),
                subtitle: Text(a.key),
                minVerticalPadding: 16,
                onTap: () => Navigator.pop(context, a.key),
              ),
            ),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == '@select-existing') {
      final directory = await chooseExistingDirectory(context, r.organization);
      if (!mounted || directory == null) return;
      final error = await r.organization.inspectRestoreDirectory(directory);
      if (!mounted) return;
      if (error != null) {
        setState(() => _message = error);
        return;
      }
      setState(() {
        _mappings[album.id] = directory.key;
        _confirmed.add(album.id);
        _preview = null;
        _manual.clear();
      });
      return;
    }
    if (_generation != r.browser.generation) return;
    setState(() {
      _mappings[album.id] = choice.isEmpty ? null : choice;
      _confirmed.add(album.id);
      _preview = null;
      _manual.clear();
    });
  }

  Future<bool> _originalPermission() async {
    var allowed = await r.originals.permission();
    if (allowed || !mounted) return allowed;
    final request = await showDialog<bool>(
      context: context,
      builder: (context) => PhotoTreeConfirmation(
        title: Text(context.tr('收藏跨设备匹配')),
        content: Text(
          context.tr(
            '为收藏核对可靠指纹，需要读取确切原始内容，原始媒体可能含位置元数据。只比较大小与 SHA256，不复制原始媒体或其元数据。可继续并保留待关联收藏，不会扩大媒体访问范围。',
          ),
        ),
        dismissLabel: context.tr('继续（不读取原始内容）'),
        onDismiss: () => Navigator.pop(context, false),
        actionLabel: context.tr('允许读取原始内容'),
        onAction: () => Navigator.pop(context, true),
      ),
    );
    if (request == null) throw RestoreProblem('已取消预览');
    if (request) {
      allowed = await r.originals.permission(request: true);
      await r.browser.refresh();
      // Permission UI invalidates all old selections; require current confirmation.
      throw RestoreProblem('权限请求已返回，请重新确认目录后生成预览');
    }
    return allowed;
  }

  Future<void> _makePreview() => _run(() async {
    final doc = _document!;
    if (_confirmed.length != doc.albums.length) {
      throw RestoreProblem(context.tr('请逐项确认每个相册的目录或暂不关联'));
    }
    final allowed = await _originalPermission();
    if (!mounted) return;
    final p = _pending
        ? await r.pendingPreview(
            _mappings,
            manualPhotos: _manual,
            readOriginals: allowed,
          )
        : await r.preview(
            doc,
            _mappings,
            manualPhotos: _manual,
            readOriginals: allowed,
          );
    if (mounted) {
      setState(() {
        _preview = p;
        _step = _Step.favorites;
      });
    }
  });
  Future<void> _manualPhoto(BackupFavorite record) async {
    final generation = r.browser.generation;
    final album = _mappings[record.albumId];
    final photos = r.browser.photos
        .where(
          (p) =>
              p.kind == record.mediaKind &&
              (album == null || p.albumKey == album),
        )
        .toList();
    final chosen = await showModalBottomSheet<Photo>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .75,
        child: ListView(
          children: [
            ListTile(
              title: Text(
                record.mediaKind == MediaKind.video
                    ? context.tr('明确选择当前可访问视频')
                    : context.tr('明确选择当前可访问图片'),
              ),
              subtitle: Text(context.tr('仅显示相同类型；选中后还需确认，不会按名称或旧编号自动关联。')),
            ),
            if (photos.isEmpty)
              BackupNotice(context.tr('当前没有可访问的同类型媒体。可以稍后处理，这条记录会保留。')),
            BackupRecords<Photo>(
              items: photos,
              label: (p) => p.directory,
              searchLabel: context.tr('搜索所在目录'),
              builder: (p) => ListTile(
                leading: _CurrentThumbnail(
                  restore: r,
                  photo: p,
                  generation: generation,
                ),
                title: FutureBuilder<String?>(
                  future: _filename(p),
                  builder: (context, name) => Text(
                    name.data ??
                        (p.kind == MediaKind.video
                            ? context.tr('视频 · 名称暂不可读')
                            : context.tr('图片 · 名称暂不可读')),
                  ),
                ),
                subtitle: Text(p.directory),
                minVerticalPadding: 16,
                onTap: () => Navigator.pop(context, p),
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted || chosen == null || generation != r.browser.generation) {
      return;
    }
    final selected = await showDialog<bool>(
      context: context,
      builder: (context) => PhotoTreeConfirmation(
        title: Text(context.tr('确认关联此媒体')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CurrentThumbnail(
              restore: r,
              photo: chosen,
              generation: generation,
              size: 160,
            ),
            FutureBuilder<String?>(
              future: _filename(chosen),
              builder: (context, name) => Text(
                context.tr('{0}\n{1}\n将其作为这条导入收藏的当前媒体。', [
                  name.data ?? context.tr('名称暂不可读'),
                  chosen.directory,
                ]),
              ),
            ),
          ],
        ),
        dismissLabel: context.tr('取消'),
        onDismiss: () => Navigator.pop(context, false),
        actionLabel: context.tr('确认媒体关联'),
        onAction: () => Navigator.pop(context, true),
      ),
    );
    if (!mounted || selected != true || generation != r.browser.generation) {
      return;
    }
    final identity = favoriteIdentity(chosen, r.browser.libraryVersion);
    if (identity == null) return;
    setState(() {
      _manual[record.identity] = identity;
      _preview = null;
    });
  }

  Future<void> _apply() => _run(() async {
    final p = _preview!;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => PhotoTreeConfirmation(
        title: Text(
          p.rollback
              ? context.tr('确认回滚私有数据')
              : p.reassociation
              ? context.tr('确认重新关联')
              : context.tr('确认整体替换'),
        ),
        content: Text(
          context.tr(
            '{0}\n已关联收藏 {1} 条，待处理收藏 {2} 条，待关联相册 {3} 个。\n{4}成功后将以本次操作前状态更新最近回滚副本，替代旧副本。不会修改系统收藏或原始媒体，不能撤销真实移动或删除。',
            [
              p.reassociation
                  ? context.tr('只更新当前待关联记录，保留当前分类与顺序。')
                  : context.tr('整体替换当前相册文件夹、分类、顺序与应用内收藏；不是合并。'),
              p.resolvedFavorites,
              p.pendingFavorites,
              p.pendingAlbums,
              p.target.organization.folders.isEmpty &&
                      p.target.organization.placements.isEmpty &&
                      p.target.organization.descriptors.isEmpty &&
                      p.target.favorites.confirmed.isEmpty &&
                      p.target.favorites.pending.isEmpty
                  ? context.tr('目标为空，将清空当前分类与收藏记录。\n')
                  : "",
            ],
          ),
        ),
        dismissLabel: context.tr('取消'),
        onDismiss: () => Navigator.pop(context, false),
        actionLabel: p.rollback
            ? context.tr('确认回滚')
            : p.reassociation
            ? context.tr('确认关联')
            : context.tr('确认替换'),
        onAction: () => Navigator.pop(context, true),
        destructive: !p.reassociation,
      ),
    );
    if (approved != true || !mounted) return;
    _committing = true;
    bool changed;
    try {
      changed = await r.apply(p);
    } finally {
      _committing = false;
    }
    if (mounted) {
      setState(() {
        _preview = null;
        _document = null;
        _result = p;
        _changed = changed;
        _step = _Step.result;
        _message = r.status;
      });
    }
  });
  int _albumCount(OrganizationSnapshot s) => {
    ...s.descriptors.keys,
    ...s.placements.keys,
    ...s.albumOrders.values.expand((a) => a),
  }.length;
  Future<void> _rollback() => _run(() async {
    final p = await r.rollbackPreview();
    if (mounted) {
      setState(() {
        _document = null;
        _preview = p;
        _step = _Step.preview;
      });
    }
  });

  void _back() {
    if (_busy) return;
    setState(() {
      _message = null;
      switch (_step) {
        case _Step.summary:
          _document = null;
          _step = _Step.select;
        case _Step.albums:
          _step = _pending ? _Step.select : _Step.summary;
          if (_pending) _document = null;
        case _Step.favorites:
          _step = _Step.albums;
        case _Step.preview:
          _step = _preview?.rollback == true ? _Step.select : _Step.favorites;
          if (_preview?.rollback == true) _preview = null;
        case _Step.select:
        case _Step.result:
          break;
      }
    });
  }

  Widget _details(String title, List<(String, String)> rows) => ExpansionTile(
    key: PageStorageKey('$title:${rows.map((r) => r.$2).join("|")}'),
    title: Text(title),
    children: [BackupSummary(rows)],
  );
  String _albumName(BackupAlbum a) =>
      a.name ??
      a.directory?.split('/').where((v) => v.isNotEmpty).lastOrNull ??
      context.tr('未命名相册');
  String _targetName(String? key) {
    if (key == null) return context.tr('暂不关联');
    final album = r.organization.restoreAlbums
        .where((a) => a.key == key)
        .firstOrNull;
    return album == null ? context.tr('已选择目录') : context.albumName(album);
  }

  Widget _albumList() {
    final all = _document!.albums;
    final items = all
        .where(
          (a) => switch (_albumFilter) {
            '未确认' => !_confirmed.contains(a.id),
            '缺失或待关联' => _mappings[a.id] == null,
            _ => true,
          },
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.tr('确认相册位置'),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        BackupNotice(
          context.tr('已确认 {0} / {1} 个。相同路径只是建议；请逐项确认目标或选择暂不关联。', [
            _confirmed.length,
            all.length,
          ]),
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final f in ['全部', '未确认', '缺失或待关联'])
              ChoiceChip(
                label: Text(context.tr(f)),
                selected: _albumFilter == f,
                onSelected: (_) => setState(() => _albumFilter = f),
              ),
          ],
        ),
        BackupRecords<BackupAlbum>(
          key: ValueKey(_albumFilter),
          items: items,
          label: (a) => '${_albumName(a)} ${a.sourceKey}',
          searchLabel: context.tr('搜索相册名称或路径'),
          builder: (a) => Card(
            child: Column(
              children: [
                ListTile(
                  title: Text(_albumName(a)),
                  subtitle: Text(
                    '${_confirmed.contains(a.id) ? context.tr('已确认') : context.tr('待确认')} · ${_targetName(_mappings[a.id])}',
                  ),
                  leading: Icon(
                    _confirmed.contains(a.id)
                        ? Icons.check_circle_outline
                        : Icons.folder_outlined,
                  ),
                  minVerticalPadding: 16,
                  onTap: _busy ? null : () => _mapping(a),
                ),
                _details(context.tr('查看位置'), [
                  (
                    context.tr('原目录'),
                    a.sourceKey ?? a.directory ?? context.tr('未知'),
                  ),
                  (
                    context.tr('当前目标'),
                    _mappings[a.id] ?? context.tr('暂不关联；记录仍保留'),
                  ),
                ]),
              ],
            ),
          ),
        ),
        if (all.isEmpty) BackupNotice(context.tr('此备份没有相册映射，可以继续核对收藏。')),
        FilledButton(
          onPressed: _busy || _confirmed.length != all.length
              ? null
              : _makePreview,
          child: Text(context.tr('核对收藏关联')),
        ),
      ],
    );
  }

  Widget _favoriteList() {
    final doc = _document!;
    final reasons = {
      for (final f in _preview?.target.favorites.pending ?? <PendingFavorite>[])
        f.identity: f.reason,
    };
    String group(BackupFavorite f) {
      if (_preview == null) return context.tr('待重新核对');
      return switch (reasons[f.identity]) {
        null => context.tr('已匹配'),
        'duplicate_content' => context.tr('重复内容'),
        'target_conflict' => context.tr('关联冲突'),
        'partial_access_requires_choice' ||
        'original_permission_declined' ||
        'original_unavailable' => context.tr('访问受限'),
        _ => context.tr('尚未匹配'),
      };
    }

    final groups = <String, List<BackupFavorite>>{};
    for (final f in doc.favorites) {
      (groups[group(f)] ??= []).add(f);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.tr('核对收藏'),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        BackupNotice(context.tr('仅恢复到 PhotoTree。未匹配记录会完整保留，可以现在选择媒体，也可以稍后处理。')),
        for (final entry in groups.entries)
          ExpansionTile(
            key: PageStorageKey('favorites-${entry.key}:${entry.value.length}'),
            title: Text(
              context.tr('{0} · {1} 条', [entry.key, entry.value.length]),
            ),
            children: [
              BackupRecords<BackupFavorite>(
                items: entry.value,
                label: (f) => f.filename ?? context.tr('名称未知'),
                searchLabel: context.tr('搜索收藏名称'),
                builder: (f) => Column(
                  children: [
                    ListTile(
                      leading: Icon(
                        f.mediaKind == MediaKind.video
                            ? Icons.videocam_outlined
                            : Icons.photo_outlined,
                      ),
                      title: Text(f.filename ?? context.tr('原文件名称未知')),
                      subtitle: Text(
                        '${f.mediaKind == MediaKind.video ? context.tr('视频') : context.tr('图片')} · ${_manual.containsKey(f.identity)
                            ? context.tr('已手动选择')
                            : reasons[f.identity] == null
                            ? entry.key
                            : _reason(context, reasons[f.identity]!)}',
                      ),
                      minVerticalPadding: 16,
                      onTap: _busy ? null : () => _manualPhoto(f),
                    ),
                    _details(context.tr('查看关联资料'), [
                      (
                        context.tr('原目录'),
                        doc.albums
                                .where((a) => a.id == f.albumId)
                                .firstOrNull
                                ?.directory ??
                            context.tr('未知'),
                      ),
                      (
                        context.tr('内容指纹'),
                        f.fingerprint == null
                            ? context.tr('未提供')
                            : context.tr('已保留'),
                      ),
                      (
                        context.tr('记录状态'),
                        f.pending ? context.tr('备份中待处理') : context.tr('备份中已收藏'),
                      ),
                    ]),
                  ],
                ),
              ),
            ],
          ),
        if (doc.favorites.isEmpty) BackupNotice(context.tr('此备份没有收藏记录。')),
        FilledButton(
          onPressed: _busy
              ? null
              : _preview == null
              ? _makePreview
              : () => setState(() => _step = _Step.preview),
          child: Text(
            _preview == null ? context.tr('重新核对收藏') : context.tr('查看变更预览'),
          ),
        ),
      ],
    );
  }

  List<Widget> _previewWidgets(RestorePreview p) {
    final current = {
      for (final photo in r.browser.photos)
        favoriteIdentity(photo, r.browser.libraryVersion): photo,
    };
    return [
      Text(
        p.rollback
            ? context.tr('回滚预览')
            : p.reassociation
            ? context.tr('关联变更预览')
            : context.tr('恢复变更预览'),
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      BackupNotice(
        p.reassociation
            ? context.tr('仅更新当前待关联记录，保留后续分类编辑。')
            : context.tr('将整体替换当前私有分类与收藏，不是合并。'),
        warning: !p.reassociation,
      ),
      BackupSummary([
        (
          context.tr('相册文件夹'),
          '${p.before.organization.folders.length} → ${p.target.organization.folders.length}',
        ),
        (
          context.tr('相册记录'),
          '${_albumCount(p.before.organization)} → ${_albumCount(p.target.organization)}',
        ),
        (
          context.tr('已关联收藏'),
          '${p.before.favorites.confirmed.length} → ${p.resolvedFavorites}',
        ),
        (
          context.tr('待处理收藏'),
          '${p.before.favorites.pending.length} → ${p.pendingFavorites}',
        ),
        (context.tr('待关联相册'), context.tr('{0} 个', [p.pendingAlbums])),
      ]),
      ExpansionTile(
        key: const PageStorageKey('target-tree'),
        title: Text(context.tr('查看目标分类与顺序')),
        children: [
          BackupRecords<String>(
            items: [
              for (final f in p.target.organization.folders.values)
                context.tr('文件夹：{0} · 上级：{1}', [
                  f.name,
                  p.target.organization.folders[f.parent]?.name ??
                      context.tr('根目录'),
                ]),
              for (final d in p.target.organization.descriptors.values)
                context.tr('相册：{0} · {1} · {2}', [
                  d.name ?? d.directory,
                  d.pending ? context.tr('待关联') : context.tr('已关联'),
                  d.directory,
                ]),
              for (final e in p.target.organization.folderOrders.entries)
                context.tr('文件夹顺序：{0} → {1}', [
                  e.key == rootFolder
                      ? context.tr('根目录')
                      : p.target.organization.folders[e.key]?.name ?? e.key,
                  e.value
                      .map(
                        (id) => p.target.organization.folders[id]?.name ?? id,
                      )
                      .join(context.usesEnglish ? ', ' : '、'),
                ]),
              for (final e in p.target.organization.albumOrders.entries)
                context.tr('相册顺序：{0} → {1}', [
                  e.key == rootFolder
                      ? context.tr('根目录')
                      : p.target.organization.folders[e.key]?.name ?? e.key,
                  e.value
                      .map(
                        (id) =>
                            p.target.organization.descriptors[id]?.name ?? id,
                      )
                      .join(context.usesEnglish ? ', ' : '、'),
                ]),
            ],
            label: (s) => s,
            builder: (s) => ListTile(title: Text(s), minVerticalPadding: 16),
          ),
        ],
      ),
      ExpansionTile(
        key: const PageStorageKey('target-confirmed'),
        title: Text(context.tr('查看已关联收藏 · {0} 条', [p.resolvedFavorites])),
        children: [
          BackupRecords<String>(
            items: p.target.favorites.confirmed.toList(),
            label: (id) => current[id]?.directory ?? context.tr('当前不可访问'),
            searchLabel: context.tr('搜索当前所在目录'),
            builder: (id) {
              final photo = current[id];
              return ListTile(
                minVerticalPadding: 16,
                leading: Icon(
                  favoriteMediaKind(id) == MediaKind.video
                      ? Icons.videocam_outlined
                      : Icons.photo_outlined,
                ),
                title: photo == null
                    ? Text(context.tr('收藏记录 · 当前不可访问'))
                    : FutureBuilder<String?>(
                        future: _filename(photo),
                        builder: (context, name) =>
                            Text(name.data ?? context.tr('名称暂不可读')),
                      ),
                subtitle: Text(
                  photo?.directory ?? context.tr('仅恢复私有记录，不恢复原文件'),
                ),
              );
            },
          ),
        ],
      ),
      if (p.pendingFavorites > 0)
        ExpansionTile(
          key: const PageStorageKey('target-pending'),
          title: Text(context.tr('查看待处理收藏 · {0} 条', [p.pendingFavorites])),
          children: [
            BackupRecords<PendingFavorite>(
              items: p.target.favorites.pending,
              label: (f) => f.filename ?? context.tr('收藏'),
              builder: (f) => ListTile(
                title: Text(f.filename ?? context.tr('名称未知')),
                subtitle: Text(_reason(context, f.reason)),
                minVerticalPadding: 16,
              ),
            ),
          ],
        ),
      BackupNotice(
        context.tr('成功后将更新最近回滚副本，替代旧副本。只恢复 PhotoTree 私有数据，不能撤销真实移动或删除。'),
      ),
      FilledButton(
        onPressed: _busy ? null : _apply,
        child: Text(
          p.rollback
              ? context.tr('确认回滚私有数据')
              : p.reassociation
              ? context.tr('确认应用关联')
              : context.tr('确认整体替换'),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && (_step == _Step.select || _step == _Step.result),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: Scaffold(
      appBar: photoTreePageBar(
        context,
        title: widget.intent == RestoreIntent.rollback
            ? context.tr('回滚私有数据')
            : _pending
            ? context.tr('处理待关联记录')
            : context.tr('从备份恢复'),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          key: PageStorageKey(
            'restore-${_step.name}-${_preview?.rollback == true}-$_pending',
          ),
          padding: const EdgeInsets.all(16),
          children: [
            CreationBlockNotice(organization: r.organization),
            if (r.busy) ...[
              const LinearProgressIndicator(),
              BackupNotice(
                _committing
                    ? context.tr('正在核对并保存，请等待结果；此时返回不能撤销提交。')
                    : context.tr('正在准备与核对…'),
              ),
              if (!_committing && r.busy)
                TextButton(
                  onPressed: r.cancelPreview,
                  child: Text(context.tr('停止准备')),
                ),
            ],
            if (_message != null)
              BackupNotice(
                _message == '备份无效：{0}。私有数据未改变。'
                    ? context.tr(_message!, [
                        context.domainText(_invalidDetail!),
                      ])
                    : context.domainText(_message!),
                key: const ValueKey('restore-result'),
                warning: _step != _Step.result,
              ),
            if (r.blocked) ...[
              BackupNotice(
                r.status ?? context.tr('私有数据恢复受阻，原材料已保留。'),
                warning: true,
              ),
              FilledButton(
                onPressed: _busy ? null : () => _run(r.retryRecovery),
                child: Text(context.tr('重试私有数据恢复')),
              ),
            ] else ...[
              if (_step == _Step.select &&
                  widget.intent != RestoreIntent.file) ...[
                FilledButton(
                  onPressed: _busy
                      ? null
                      : widget.intent == RestoreIntent.pending
                      ? () => _setDocument(r.pendingDocument(), true)
                      : r.hasRollback
                      ? _rollback
                      : null,
                  child: Text(
                    widget.intent == RestoreIntent.pending
                        ? context.tr('重新处理待关联记录')
                        : context.tr('重新查看回滚副本'),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.maybePop(context),
                  child: Text(context.tr('返回备份与恢复')),
                ),
              ],
              if (_step == _Step.select &&
                  widget.intent == RestoreIntent.file) ...[
                Text(
                  context.tr('选择分类与收藏备份'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                BackupNotice(context.tr('先查看文件摘要，再确认关联和变更。选择文件本身不会替换数据。')),
                FilledButton(
                  onPressed: _busy ? null : _choose,
                  child: Text(context.tr('选择备份文件')),
                ),
              ],
              if (_document case final d? when _step == _Step.summary) ...[
                Text(
                  context.tr('备份文件摘要'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                BackupSummary([
                  (
                    context.tr('相册文件夹'),
                    context.tr('{0} 个', [d.organization.folders.length]),
                  ),
                  (context.tr('相册'), context.tr('{0} 个', [d.albums.length])),
                  (
                    context.tr('图片收藏'),
                    context.tr('{0} 条', [
                      d.favorites
                          .where((f) => f.mediaKind == MediaKind.image)
                          .length,
                    ]),
                  ),
                  (
                    context.tr('视频收藏'),
                    context.tr('{0} 条', [
                      d.favorites
                          .where((f) => f.mediaKind == MediaKind.video)
                          .length,
                    ]),
                  ),
                ]),
                BackupNotice(
                  context.tr('恢复会整体替换当前分类与应用内收藏。接下来仍需逐项关联、查看变更和最终确认。'),
                  warning: true,
                ),
                _details(context.tr('格式兼容'), [
                  (
                    context.tr('兼容说明'),
                    context.tr(
                      '支持 v1 / v2 / v3；v1 / v2 按图片解释。所有匹配收藏只恢复到 PhotoTree，不采集或写入当前系统收藏。',
                    ),
                  ),
                ]),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _step = _Step.albums),
                  child: Text(context.tr('开始关联相册')),
                ),
              ],
              if (_step == _Step.albums && _document != null) _albumList(),
              if (_step == _Step.favorites && _document != null)
                _favoriteList(),
              if (_preview case final p? when _step == _Step.preview)
                ..._previewWidgets(p),
              if (_result case final p? when _step == _Step.result) ...[
                Text(
                  !_changed
                      ? context.tr('没有关联变化')
                      : p.pendingAlbums + p.pendingFavorites > 0
                      ? context.tr('已保存，仍有待关联记录')
                      : context.tr('私有数据已恢复'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                BackupSummary([
                  (
                    context.tr('已关联收藏记录'),
                    context.tr('{0} 条', [p.resolvedFavorites]),
                  ),
                  (
                    context.tr('当前可访问的收藏'),
                    r.browser.phase == BrowsePhase.ready
                        ? context.tr('{0} 项', [
                            r.browser.photos
                                .where(
                                  (photo) =>
                                      p.target.favorites.confirmed.contains(
                                        favoriteIdentity(
                                          photo,
                                          r.browser.libraryVersion,
                                        ),
                                      ),
                                )
                                .length,
                          ])
                        : context.tr('媒体状态尚不可确认'),
                  ),
                  (
                    context.tr('待处理收藏'),
                    context.tr('{0} 条', [p.pendingFavorites]),
                  ),
                  (context.tr('待关联相册'), context.tr('{0} 个', [p.pendingAlbums])),
                ]),
                BackupNotice(context.tr('已关联记录不等于原文件始终可访问。原始媒体及系统收藏未改变。')),
                if (p.pendingAlbums + p.pendingFavorites > 0)
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _setDocument(r.pendingDocument(), true),
                    child: Text(context.tr('继续处理待关联记录')),
                  ),
                if (r.hasRollback)
                  OutlinedButton(
                    onPressed: _busy ? null : _rollback,
                    child: Text(context.tr('查看最近回滚副本')),
                  ),
                TextButton(
                  onPressed: () => Navigator.maybePop(context),
                  child: Text(context.tr('返回备份与恢复')),
                ),
              ],
              if (_document != null && _step != _Step.result)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _document = null;
                          _preview = null;
                          _step = _Step.select;
                          _message = '已取消本次准备，分类和收藏未替换。已授予的系统目录权限仍由系统保留。';
                        }),
                  child: Text(context.tr('取消本次准备')),
                ),
            ],
          ],
        ),
      ),
    ),
  );
}

String _reason(BuildContext context, String value) => switch (value) {
  'awaiting_system_confirmation' => context.tr('历史待处理记录，需重新核对'),
  'target_conflict' => context.tr('多条记录指向同一媒体，已保留待处理'),
  'album_not_associated' => context.tr('相册尚未关联'),
  'missing_fingerprint' => context.tr('缺少指纹'),
  'unknown_library_version' => context.tr('媒体库身份未知'),
  'partial_access_requires_choice' => context.tr('部分授权，请明确选择媒体'),
  'original_permission_declined' => context.tr('未读取原始内容'),
  'duplicate_content' => context.tr('存在重复内容，请明确选择媒体'),
  'original_unavailable' => context.tr('原图暂不可读'),
  'no_match' => context.tr('没有内容匹配'),
  _ => context.tr('当前不可访问'),
};

class _CurrentThumbnail extends StatelessWidget {
  const _CurrentThumbnail({
    required this.restore,
    required this.photo,
    required this.generation,
    this.size = 48,
  });
  final BackupRestore restore;
  final Photo photo;
  final int generation;
  final double size;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: restore.browser,
    builder: (context, _) {
      if (!restore.browser.current(generation)) {
        return SizedBox(
          width: size,
          height: size,
          child: const Icon(Icons.image_not_supported),
        );
      }
      return SizedBox(
        width: size,
        height: size,
        child: FutureBuilder(
          future: restore.browser.thumbnail(photo, 256, generation),
          builder: (context, snapshot) =>
              snapshot.hasData && restore.browser.current(generation)
              ? Image.memory(
                  snapshot.data!,
                  fit: BoxFit.cover,
                  gaplessPlayback: false,
                )
              : const Icon(Icons.photo_outlined),
        ),
      );
    },
  );
}

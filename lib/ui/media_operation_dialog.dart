import 'interface_strings.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../library/physical_operations.dart';
import '../media/browser.dart';
import '../media/media_source.dart';
import '../organization/organization.dart';
import '../storage/directory_access.dart';
import 'album_target_picker.dart';
import 'physical_operations_page.dart';
import 'visual_style.dart';
import 'dialog_action_bar.dart';

Future<PhysicalBatch?> showMediaOperationDialog(
  BuildContext context, {
  required PhysicalOperations operations,
  required List<Photo> photos,
  required PhysicalKind kind,
}) async {
  final selectedPhotos = List<Photo>.unmodifiable(photos);
  Album? target;
  bool available(Album album) =>
      physicalAlbumDirectory(album) != null &&
      (album.availability == AlbumAvailability.indexed ||
          album.availability == AlbumAvailability.empty);
  if (kind == PhysicalKind.move) {
    final key = await showDialog<String>(
      context: context,
      builder: (_) => AlbumTargetPicker(
        organization: operations.organization,
        canSelect: available,
        disabledReason: (_) => context.tr('此相册目前无法接收媒体，请刷新或检查访问权限'),
      ),
    );
    if (!context.mounted || key == null) return null;
    target = operations.organization.albums
        .where((a) => a.key == key && available(a))
        .firstOrNull;
    if (target == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.tr('目标相册已变化，请重新选择'))));
      return null;
    }
  }
  if (!context.mounted) return null;
  final result = await showDialog<PhysicalBatch>(
    context: context,
    barrierDismissible: false,
    builder: (_) => MediaOperationDialog(
      operations: operations,
      photos: selectedPhotos,
      kind: kind,
      target: target,
    ),
  );
  if (context.mounted &&
      result != null &&
      result.items.every(
        (i) =>
            (i.outcome == PhysicalOutcome.confirmed && i.privateCommitted) ||
            i.outcome == PhysicalOutcome.unchanged,
      )) {
    final completed = result.items
        .where((i) => i.outcome == PhysicalOutcome.confirmed)
        .length;
    final unchanged = result.items.length - completed;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          persist: false,
          duration: const Duration(seconds: 4),
          content: Text(
            context.tr('{0} {1} 项{2}', [
              kind == PhysicalKind.move ? context.tr('已移动') : context.tr('已删除'),
              completed,
              unchanged == 0 ? '' : context.tr('，{0} 项已在目标相册', [unchanged]),
            ]),
          ),
          action: SnackBarAction(
            label: context.tr('查看详情'),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => PhysicalOperationsPage(operations: operations),
              ),
            ),
          ),
        ),
      );
  }
  return result;
}

/// Owns only this confirmation's captured selection, target and presentation.
/// PhysicalOperations owns the batch, durable journal and execution guard.
class MediaOperationDialog extends StatefulWidget {
  const MediaOperationDialog({
    super.key,
    required this.operations,
    required this.photos,
    required this.kind,
    this.target,
  });
  final PhysicalOperations operations;
  final List<Photo> photos;
  final PhysicalKind kind;
  final Album? target;
  @override
  State<MediaOperationDialog> createState() => _MediaOperationDialogState();
}

class _MediaOperationDialogState extends State<MediaOperationDialog> {
  PhysicalOperations get op => widget.operations;
  bool _running = false, _confirmed = false, _needsDirectory = false;
  bool _preparing = false;
  PhysicalBatch? _batch;
  String? _error;
  String? _version;
  late MediaPermissions _permissions;
  bool _accessChanged = false;
  void _observeAccess() {
    if (op.browser.permissions != _permissions ||
        (op.browser.libraryVersion != null &&
            op.browser.libraryVersion != _version)) {
      _accessChanged = true;
    }
  }

  bool get moving => widget.kind == PhysicalKind.move;
  @override
  void initState() {
    super.initState();
    _version = op.browser.libraryVersion;
    _permissions = op.browser.permissions;
    op.browser.addListener(_observeAccess);
  }

  bool _sameTarget() {
    if (!moving) return true;
    final target = widget.target;
    return target != null &&
        op.organization.albums.any(
          (a) =>
              a.key == target.key &&
              a.directory == target.directory &&
              (a.availability == AlbumAvailability.indexed ||
                  a.availability == AlbumAvailability.empty),
        );
  }

  String _pathFor(Album target) {
    final org = op.organization;
    return [
      ...org.snapshot
          .path(org.snapshot.parentOfAlbum(target.key))
          .map(
            (id) => id == rootFolder
                ? context.tr('相册')
                : org.snapshot.folders[id]?.name ?? context.tr('位置已变化'),
          ),
      context.albumName(target),
    ].join(' / ');
  }

  Future<void> _run({bool authorizeDirectory = false}) async {
    if (_running || op.busy || op.blocked) return;
    setState(() {
      _confirmed = true;
      _running = true;
      _error = null;
    });
    try {
      final access = op.organization.directories;
      final target = widget.target;
      if (_accessChanged ||
          !_sameTarget() ||
          op.browser.libraryVersion != _version) {
        _error = '媒体或目标相册已变化，请重新选择';
        return;
      }
      if (moving && target != null && access != null) {
        final directory = physicalAlbumDirectory(target)!;
        final capabilities = await access.inspect(directory);
        if (!mounted) return;
        if (capabilities.status == DirectoryStatus.needsAuthorization ||
            capabilities.status == DirectoryStatus.revoked) {
          if (!authorizeDirectory) {
            setState(() => _needsDirectory = true);
            return;
          }
          _needsDirectory = false;
          final result = await access.authorize(directory);
          if (!mounted) return;
          if (result != DirectoryRequest.granted) {
            _error = '未获得相册访问权限，没有移动任何文件';
            return;
          }
          await op.browser.refresh();
          final refreshed = await op.browser.waitForRefresh();
          if (!mounted) return;
          if (!refreshed) {
            _error = '相册访问已允许，但媒体仍未准备好，请稍后重新选择';
            return;
          }
        } else if (capabilities.status != DirectoryStatus.available) {
          _error = '此相册目前无法接收媒体，请刷新后重试';
          return;
        }
      }
      if (!mounted) return;
      if (_accessChanged ||
          !_sameTarget() ||
          op.browser.libraryVersion != _version ||
          op.browser.phase != BrowsePhase.ready) {
        _error = '媒体或目标相册已变化，请重新选择';
        return;
      }
      _needsDirectory = false;
      if (op.busy || op.blocked || op.preview != null) {
        _error = '另一项操作正在进行，请稍后重新选择';
        return;
      }
      _preparing = true;
      final prepared = await op.preparePhotos(
        widget.photos,
        kind: widget.kind,
        targetDirectory: target?.directory,
      );
      _preparing = false;
      if (!mounted) {
        if (prepared != null && identical(op.preview, prepared) && !op.busy) {
          op.cancelPreview();
        }
        return;
      }
      if (prepared == null) {
        _error = '无法准备本次操作，请检查媒体和访问权限后重新选择';
        return;
      }
      _batch = prepared;
      if (_accessChanged ||
          !_sameTarget() ||
          op.browser.libraryVersion != _version) {
        op.cancelPreview();
        _error = '媒体或目标相册已变化，请重新选择';
        return;
      }
      await op.execute();
      if (!mounted) return;
      _batch =
          op.records.where((b) => b.id == prepared.id).firstOrNull ?? prepared;
      final batch = _batch!;
      if (!op.blocked &&
          batch.items.every(
            (i) =>
                (i.outcome == PhysicalOutcome.confirmed &&
                    i.privateCommitted) ||
                i.outcome == PhysicalOutcome.unchanged,
          )) {
        Navigator.pop(context, batch);
      } else if (op.blocked) {
        _error = '部分结果尚待确认。可在操作记录中查看，不会自动重做。';
      }
    } catch (_) {
      if (mounted) _error = '本次操作未完成，请检查媒体及访问权限后重新选择。';
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  void dispose() {
    op.browser.removeListener(_observeAccess);
    final batch = _batch;
    if (batch != null && identical(op.preview, batch) && !op.busy) {
      scheduleMicrotask(() {
        if (identical(op.preview, batch) && !op.busy) op.cancelPreview();
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: op,
    builder: (context, _) {
      final current = _batch == null
          ? null
          : op.records.where((b) => b.id == _batch!.id).firstOrNull;
      final completed =
          current?.items
              .where(
                (i) =>
                    i.outcome == PhysicalOutcome.confirmed &&
                    i.privateCommitted,
              )
              .length ??
          0;
      final unchanged =
          current?.items
              .where((i) => i.outcome == PhysicalOutcome.unchanged)
              .length ??
          0;
      final colors = Theme.of(context).colorScheme;
      final done = _confirmed && !_running && !_needsDirectory;
      final duplicates =
          widget.target != null &&
          op.organization.albums
                  .where((a) => a.name == widget.target!.name)
                  .length >
              1;
      final target = widget.target;
      final targetPath = target == null ? '' : _pathFor(target);
      final needsStoragePath =
          duplicates &&
          op.organization.albums
                  .where(
                    (a) => a.name == target!.name && _pathFor(a) == targetPath,
                  )
                  .length >
              1;
      return PopScope(
        canPop: !_running,
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          constraints: const BoxConstraints(maxWidth: 340),
          clipBehavior: Clip.antiAlias,
          child: GlassSurface(
            highOpacity: true,
            borderRadius: PhotoTreeStyle.panelRadius,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Padding(
                padding: EdgeInsets.zero,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (!_confirmed &&
                                  !moving &&
                                  MediaQuery.sizeOf(context).height >= 480 &&
                                  MediaQuery.textScalerOf(context).scale(16) <=
                                      24) ...[
                                Center(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: colors.surfaceContainerHighest,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const SizedBox.square(
                                      dimension: 32,
                                      child: Icon(
                                        Icons.delete_outline,
                                        size: 17,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],
                              Text(
                                _running
                                    ? (moving
                                          ? context.tr('正在移动媒体')
                                          : context.tr('正在删除媒体'))
                                    : done
                                    ? context.tr('处理结果')
                                    : context.tr('{0} {1} 项媒体？', [
                                        moving
                                            ? context.tr('移动')
                                            : context.tr('永久删除'),
                                        widget.photos.length,
                                      ]),
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .dialogTheme
                                    .titleTextStyle,
                              ),
                              const SizedBox(height: 12),
                              if (!_confirmed) ...[
                                if (moving)
                                  Text(
                                    context.tr('移到「{0}」', [
                                      context.albumName(widget.target!),
                                    ]),
                                    textAlign: TextAlign.center,
                                  ),
                                if (duplicates) Text(targetPath),
                                if (needsStoragePath)
                                  Text(widget.target!.directory),
                                Text(
                                  context.selectionSummary(widget.photos),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 16),
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: colors.onSurface.withValues(
                                      alpha: .06,
                                    ),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: moving
                                        ? Text(
                                            context.tr(
                                              '原文件将移入目标相册，系统相册也会更新。同名文件将自动加后缀，不覆盖已有文件。',
                                            ),
                                          )
                                        : Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                context.tr(
                                                  '这些文件将从设备中永久删除，并影响系统相册。',
                                                ),
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                context.tr(
                                                  'PhotoTree 的备份无法恢复原文件。',
                                                ),
                                                style: TextStyle(
                                                  color:
                                                      colors.onSurfaceVariant,
                                                ),
                                              ),
                                            ],
                                          ),
                                  ),
                                ),
                              ],
                              if (_needsDirectory)
                                Text(
                                  context.tr('允许 PhotoTree 使用「{0}」相册，才能移入文件。', [
                                    context.albumName(widget.target!),
                                  ]),
                                ),
                              if (_running) ...[
                                const LinearProgressIndicator(),
                                const SizedBox(height: 12),
                                Text(
                                  current?.authorizationPending == true
                                      ? context.tr('等待系统许可')
                                      : current == null
                                      ? context.tr('正在准备…')
                                      : context.tr('已完成 {0} / {1}', [
                                          completed,
                                          widget.photos.length,
                                        ]),
                                ),
                                if (widget.photos.length > 500)
                                  Text(
                                    context.tr('本次最多分 {0} 组请求系统许可', [
                                      (widget.photos.length / 500).ceil(),
                                    ]),
                                  ),
                              ],
                              if (done && current != null)
                                Text(
                                  context.tr('已完成 {0} 项，{1} 项未完成{2}', [
                                    completed,
                                    current.items.length -
                                        completed -
                                        unchanged,
                                    unchanged == 0
                                        ? ''
                                        : context.tr('，{0} 项无需移动', [unchanged]),
                                  ]),
                                ),
                              if (_error != null)
                                Text(context.domainText(_error!)),
                              if (!_confirmed && (op.busy || op.blocked))
                                Text(
                                  op.blocked
                                      ? context.tr('上次操作的结果待确认，请先在操作记录中查看。')
                                      : context.tr('另一项操作正在进行，请稍后重试。'),
                                ),
                              if (done && current != null)
                                ExpansionTile(
                                  tilePadding: EdgeInsets.zero,
                                  title: Text(context.tr('查看详情')),
                                  children: [
                                    for (final item in current.items)
                                      ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        title: Text(
                                          item.after?.displayName ??
                                              item.snapshot.displayName,
                                        ),
                                        subtitle: Text(
                                          item.outcome ==
                                                      PhysicalOutcome
                                                          .confirmed &&
                                                  !item.privateCommitted
                                              ? context.tr('文件已处理，应用内记录待确认')
                                              : physicalOutcomeText(
                                                  context,
                                                  item.outcome,
                                                  item.state,
                                                ),
                                        ),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    DialogActionBar(
                      tonal: !_confirmed,
                      dismissLabel: _running
                          ? null
                          : (done ? context.tr('关闭') : context.tr('取消')),
                      onDismiss: () =>
                          Navigator.pop(context, done ? current : null),
                      actionLabel: !_confirmed
                          ? (moving ? context.tr('移动') : context.tr('永久删除'))
                          : _needsDirectory && !_running
                          ? context.tr('选择此文件夹')
                          : _running
                          ? context.tr('停止剩余项')
                          : null,
                      actionKey: !_confirmed
                          ? const ValueKey('confirm-media-operation')
                          : null,
                      destructive: !moving && !_confirmed,
                      onAction: !_confirmed
                          ? (op.busy || op.blocked ? null : _run)
                          : _needsDirectory && !_running
                          ? () => _run(authorizeDirectory: true)
                          : _running &&
                                op.busy &&
                                (_preparing || _batch != null)
                          ? op.cancelRemaining
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

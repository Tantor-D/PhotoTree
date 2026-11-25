import 'interface_strings.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import 'visual_style.dart';

import '../library/physical_operations.dart';
import '../media/media_source.dart';
import '../storage/directory_access.dart';
import '../media/browser.dart';
import 'album_target_picker.dart';

DirectoryIdentity? physicalAlbumDirectory(Album album) {
  final separator = album.key.indexOf(':');
  if (separator <= 0 || album.key.startsWith('@')) return null;
  final directory = DirectoryIdentity(
    album.key.substring(0, separator),
    album.directory,
  );
  return directory.supported ? directory : null;
}

String physicalOutcomeText(
  BuildContext context,
  PhysicalOutcome? outcome,
  PhysicalItemState state,
) => switch (outcome) {
  PhysicalOutcome.confirmed => context.tr('已核对完成'),
  PhysicalOutcome.unchanged => context.tr('已在目标相册，无需移动'),
  PhysicalOutcome.cancelled => context.tr('已取消或未开始'),
  PhysicalOutcome.permission => context.tr('访问权限不足'),
  PhysicalOutcome.stale => context.tr('对象已变化，请重新选择'),
  PhysicalOutcome.unsupported => context.tr('当前无法执行'),
  PhysicalOutcome.failed => context.tr('未完成'),
  PhysicalOutcome.unknown => context.tr('结果待核对，不会自动重做'),
  PhysicalOutcome.busy => context.tr('其他操作正在进行'),
  null =>
    state == PhysicalItemState.inFlight
        ? context.tr('正在处理并核对')
        : context.tr('尚未开始'),
};

class PhysicalOperationsPage extends StatefulWidget {
  const PhysicalOperationsPage({
    super.key,
    required this.operations,
    this.photos,
    this.kind = PhysicalKind.delete,
    this.album,
    this.directoryAccess,
  });
  final PhysicalOperations operations;
  final List<Photo>? photos;
  final PhysicalKind kind;
  final DirectoryIdentity? album;
  final DirectoryAccess? directoryAccess;
  @override
  State<PhysicalOperationsPage> createState() => _PhysicalOperationsPageState();
}

class _PhysicalOperationsPageState extends State<PhysicalOperationsPage> {
  PhysicalOperations get op => widget.operations;
  bool authorizing = false;
  bool _leftByPop = false;
  String? message;
  String? target;
  bool get history => widget.photos == null && widget.album == null;
  @override
  void initState() {
    super.initState();
    if (!history && widget.kind != PhysicalKind.move) {
      WidgetsBinding.instance.addPostFrameCallback((_) => prepare());
    }
  }

  Future<void> prepare() async {
    if (!mounted) return;
    final operations = op;
    PhysicalBatch? prepared;
    if (widget.album != null) {
      prepared = await operations.prepareAlbum(widget.album!);
    } else if (widget.photos != null) {
      prepared = await operations.preparePhotos(
        widget.photos!,
        kind: widget.kind,
        targetDirectory: target,
      );
    }
    if ((!mounted || _leftByPop) &&
        prepared != null &&
        identical(operations.preview, prepared) &&
        !operations.busy) {
      operations.cancelPreview();
    }
  }

  DirectoryAccess? get directoryAccess =>
      widget.directoryAccess ?? op.organization.directories;

  Future<void> authorize() async {
    final access = directoryAccess;
    if (access == null) return;
    DirectoryIdentity directory;
    if (widget.album != null) {
      final album = widget.album!;
      final parts = album.path.split('/').where((p) => p.isNotEmpty).toList();
      if (parts.length < 2) return;
      directory = DirectoryIdentity(
        album.volume,
        '${parts.take(parts.length - 1).join('/')}/',
      );
    } else {
      if (target == null) return;
      directory = DirectoryIdentity('external_primary', target!);
    }
    final originalAccess = op.browser.access;
    final originalVersion = op.browser.libraryVersion;
    var accessChanged = false;
    void observeAccess() {
      if (op.browser.access != originalAccess ||
          (op.browser.libraryVersion != null &&
              op.browser.libraryVersion != originalVersion)) {
        accessChanged = true;
      }
    }

    op.browser.addListener(observeAccess);
    op.cancelPreview();
    setState(() {
      authorizing = true;
      message = null;
    });
    try {
      final result = await access.authorize(directory);
      if (!mounted) return;
      if (result == DirectoryRequest.granted) {
        await op.browser.refresh();
        for (var attempt = 0; attempt < 3; attempt++) {
          if (!await op.browser.waitForRefresh() || !mounted || accessChanged) {
            break;
          }
          final generation = op.browser.generation;
          // Always revalidate the original selection; never replay execution.
          await prepare();
          if (!mounted) return;
          if (op.preview != null || op.browser.generation == generation) break;
        }
        if (!mounted) return;
        if (accessChanged) op.cancelPreview();
        setState(
          () => message = op.preview != null
              ? '目录授权已完成，已重新核对；仍需明确确认后才执行'
              : '目录授权已完成，但媒体核对未完成；没有开始操作，请重新选择并核对',
        );
      } else {
        setState(
          () => message = result == DirectoryRequest.cancelled
              ? '已取消目录授权，没有开始操作'
              : '未完成目录授权，请选中指定目录',
        );
      }
    } catch (_) {
      if (mounted) setState(() => message = '目录授权未完成，请重试');
    } finally {
      op.browser.removeListener(observeAccess);
      if (mounted) setState(() => authorizing = false);
    }
  }

  Future<void> chooseTarget() async {
    bool canSelect(Album album) =>
        physicalAlbumDirectory(album) != null &&
        (album.availability == AlbumAvailability.indexed ||
            album.availability == AlbumAvailability.empty);
    String? initialKey;
    for (final album in op.organization.albums) {
      if (album.directory == target && canSelect(album)) initialKey = album.key;
    }
    final selected = await showDialog<String>(
      context: context,
      builder: (_) => AlbumTargetPicker(
        organization: op.organization,
        canSelect: canSelect,
        disabledReason: (album) => physicalAlbumDirectory(album) == null
            ? context.tr('仅支持主存储 Pictures / DCIM 内的真实相册')
            : (album.status == null
                      ? null
                      : context.domainText(album.status!)) ??
                  context.tr('相册当前不可访问，请刷新并检查权限'),
        initialAlbumKey: initialKey,
      ),
    );
    if (!mounted || _leftByPop || selected == null) return;
    Album? latest;
    if (op.browser.phase == BrowsePhase.ready) {
      for (final album in op.organization.albums) {
        if (album.key == selected && canSelect(album)) latest = album;
      }
    }
    if (latest == null || op.busy || op.blocked) {
      op.cancelPreview();
      setState(() => message = '目标相册或访问权限已变化，请重新选择');
      return;
    }
    op.cancelPreview();
    setState(() {
      target = latest!.directory;
      message = null;
    });
    await prepare();
  }

  @override
  void dispose() {
    // Normal back navigation cancels in PopScope, before this subtree unmounts.
    // A parent can also remove the page without popping it. Defer that fallback
    // notification until the widget tree unlocks, and never cancel a newer
    // preview or a running operation owned by another lifecycle.
    final operations = op;
    final leavingPreview = history || _leftByPop ? null : operations.preview;
    if (leavingPreview != null) {
      scheduleMicrotask(() {
        if (!operations.busy && identical(operations.preview, leavingPreview)) {
          operations.cancelPreview();
        }
      });
    }
    super.dispose();
  }

  Widget batch(PhysicalBatch b) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            b.album != null
                ? context.tr('删除真实相册：{0}', [b.album!.path])
                : b.kind == PhysicalKind.move
                ? context.tr('移动 {0} 项 · {1}', [
                    b.items.length,
                    context.selectionSummary(
                      b.items.map((i) => i.snapshot.photo),
                    ),
                  ])
                : context.tr('永久删除 {0} 项 · {1}', [
                    b.items.length,
                    context.selectionSummary(
                      b.items.map((i) => i.snapshot.photo),
                    ),
                  ]),
          ),
          if (b.targetDirectory != null)
            Text(context.tr('目标：{0}', [b.targetDirectory])),
          for (final item in b.items)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(item.snapshot.displayName),
              subtitle: Text(
                '${item.snapshot.photo.directory}\n${item.outcome == PhysicalOutcome.confirmed && !item.privateCommitted ? context.tr('媒体已处理，应用内记录待补齐') : physicalOutcomeText(context, item.outcome, item.state)}${item.after == null ? '' : context.tr('\n实际文件名：{0}\n{1}', [item.after!.displayName, item.after!.photo.directory])}',
              ),
            ),
          if (b.album != null)
            Text(
              context.tr('相册目录：{0}', [
                b.directoryOutcome == PhysicalOutcome.confirmed &&
                        !b.directoryPrivateCommitted
                    ? context.tr('目录已处理，应用内记录待补齐')
                    : physicalOutcomeText(
                        context,
                        b.directoryOutcome,
                        b.directoryState,
                      ),
              ]),
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: op,
    builder: (context, _) {
      final preview = op.preview;
      final idle = !op.busy && !authorizing;
      final issue = op.issue?.replaceFirst('Bad state: ', '');
      return PopScope(
        canPop: idle,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) return;
          _leftByPop = true;
          if (!history && !op.busy) op.cancelPreview();
        },
        child: Scaffold(
          appBar: photoTreePageBar(
            context,
            title: history
                ? context.tr('真实操作记录')
                : widget.kind == PhysicalKind.move
                ? context.tr('移动媒体')
                : widget.album != null
                ? context.tr('删除真实相册')
                : context.tr('删除媒体'),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!history && widget.kind == PhysicalKind.delete)
                Text(
                  context.tr(
                    '这会删除共享存储中的图片、视频或相册，并影响系统相册。PhotoTree 的备份不能恢复被删除的原文件。',
                  ),
                ),
              if (history)
                Text(context.tr('中断后不会自动重复移动或删除。重新核对只读取当前结果，并补齐已确认操作的应用内记录。')),
              if (widget.album != null)
                Text(context.tr('真实目录：{0}', [widget.album!.path])),
              if (widget.kind == PhysicalKind.move && !history) ...[
                Text(context.tr('先选择目标并核对。已有同名文件时会使用后缀名称，不覆盖；结果会显示实际文件名。')),
                Text(context.tr('目标：{0}', [target ?? context.tr('尚未选择')])),
                TextButton(
                  onPressed: idle && !op.blocked ? chooseTarget : null,
                  child: Text(context.tr('选择目标相册')),
                ),
                if (target != null && directoryAccess != null)
                  TextButton(
                    onPressed: idle && !op.blocked ? authorize : null,
                    child: Text(context.tr('授权目标目录并重新核对')),
                  ),
              ],
              if (issue != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    RegExp(r'[\u4e00-\u9fff]').hasMatch(issue)
                        ? context.domainText(issue)
                        : context.tr('本次核对未完成，请检查权限及媒体状态后重试'),
                  ),
                ),
              if (message != null) Text(context.domainText(message!)),
              if (!idle) const LinearProgressIndicator(),
              if (op.busy)
                TextButton(
                  onPressed: op.cancelRemaining,
                  child: Text(context.tr('停止尚未开始的项目')),
                ),
              if (preview != null && !history) ...[
                batch(preview),
                Text(
                  preview.album != null && preview.items.isEmpty
                      ? context.tr('已核对为空相册。确认后删除这个真实目录。')
                      : context.tr('请核对以上对象。系统可能显示确认提示；已完成的项目不会因停止而撤销。'),
                ),
                FilledButton(
                  onPressed: idle ? op.execute : null,
                  child: Text(
                    preview.kind == PhysicalKind.move
                        ? context.tr('确认移动')
                        : preview.album != null
                        ? context.tr('确认删除相册及上述媒体')
                        : context.tr('确认删除上述媒体'),
                  ),
                ),
                TextButton(
                  onPressed: idle
                      ? () {
                          op.cancelPreview();
                          Navigator.pop(context);
                        }
                      : null,
                  child: Text(context.tr('取消，不执行')),
                ),
              ] else if (!history && widget.kind != PhysicalKind.move) ...[
                TextButton(
                  onPressed: idle && !op.blocked ? prepare : null,
                  child: Text(context.tr('重新核对所选对象')),
                ),
                if (widget.album != null && directoryAccess != null)
                  TextButton(
                    onPressed: idle ? authorize : null,
                    child: Text(context.tr('授权相册的父目录')),
                  ),
              ],
              if (preview == null)
                TextButton(
                  onPressed: idle ? op.reconcile : null,
                  child: Text(context.tr('重新核对历史结果（不重做）')),
                ),
              for (final record in op.records.reversed) batch(record),
              if (history && op.records.isEmpty) Text(context.tr('暂无真实操作记录')),
            ],
          ),
        ),
      );
    },
  );
}

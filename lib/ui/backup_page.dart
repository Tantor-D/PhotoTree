import 'interface_strings.dart';

import 'package:flutter/material.dart';

import 'visual_style.dart';
import 'backup_widgets.dart';
import '../library/favorites.dart';
import '../media/media_source.dart';

import 'dialog_action_bar.dart';

import 'physical_album_page.dart';

import '../backup/backup_export.dart';

class BackupPage extends StatefulWidget {
  const BackupPage({super.key, required this.backup});
  final BackupExport backup;
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool _busy = false;
  String? _message;
  List<int> _progress = const [];
  ExportResult? _result;
  bool _failed = false;
  bool _preparing = false, _stopping = false;
  Future<void> _export() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _result = null;
      _failed = false;
      _stopping = false;
    });
    try {
      var allowed = await widget.backup.originals.permission();
      if (!mounted) return;
      if (!allowed) {
        final request = await showDialog<bool>(
          context: context,
          builder: (context) => PhotoTreeConfirmation(
            title: Text(context.tr('收藏跨设备匹配')),
            content: Text(
              context.tr(
                '为收藏计算可靠指纹，需要读取确切的原始内容；原始媒体可能包含位置元数据。备份只保存大小与 SHA256，不包含原始媒体或其元数据。可拒绝并继续导出，相关收藏将保留为未解析。不会扩大媒体访问范围。',
              ),
            ),
            dismissLabel: context.tr('继续导出（不读取原始内容）'),
            onDismiss: () => Navigator.pop(context, false),
            actionLabel: context.tr('允许读取原始内容'),
            onAction: () => Navigator.pop(context, true),
          ),
        );
        if (request == null) {
          if (mounted) setState(() => _message = '已取消导出');
          return;
        }
        if (request) {
          allowed = await widget.backup.originals.permission(request: true);
          // Runtime permission UI can invalidate the media ticket. Refresh before snapshot.
          await widget.backup.browser.refresh();
        }
      }
      if (!mounted) return;
      setState(() {
        _message = '准备备份…';
        _preparing = true;
      });
      final result = await widget.backup.export(
        readOriginals: allowed,
        onProgress: (completed, total) {
          if (mounted && !_stopping) {
            setState(() {
              _message = '正在准备收藏匹配资料：{0} / {1} 条';
              _progress = [completed, total];
            });
          }
        },
        onOutput: () {
          if (mounted) {
            setState(() {
              _preparing = false;
              _message = '选择保存位置…';
            });
          }
        },
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _message = result.saved ? '备份已保存' : '已取消导出，应用数据未改变。';
      });
    } on BackupPreparationCancelled {
      if (mounted) {
        setState(() => _message = '已停止准备，未保存备份，应用数据未改变。');
      }
    } on BackupMediaRefreshing {
      if (mounted) setState(() => _message = '媒体列表正在刷新，请稍后重试导出。');
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _message = '导出失败，不能将此次输出当作有效备份。分类、收藏和媒体未改变；保存位置可能留下不完整文件，请重试。';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _preparing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.backup.browser,
      widget.backup.organization,
      widget.backup.favorites,
    ]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final snapshot = widget.backup.favorites.snapshot;
    final kinds = [
      for (final id in snapshot.confirmed) favoriteMediaKind(id),
      for (final f in snapshot.pending) favoriteMediaKind(f.identity),
    ];
    final d = _result?.saved == true ? _result!.document : null;
    final images =
        d?.favorites.where((f) => f.mediaKind == MediaKind.image).length ??
        kinds.where((k) => k == MediaKind.image).length;
    final videos =
        d?.favorites.where((f) => f.mediaKind == MediaKind.video).length ??
        kinds.where((k) => k == MediaKind.video).length;
    return PopScope(
      canPop: !_busy || _stopping,
      child: Scaffold(
        appBar: photoTreePageBar(context, title: context.tr('导出备份')),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              CreationBlockNotice(organization: widget.backup.organization),
              Text(
                d == null ? context.tr('保存你的整理成果') : context.tr('备份已保存'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              BackupSummary([
                (
                  context.tr('相册文件夹'),
                  context.tr('{0} 个', [
                    d?.organization.folders.length ??
                        widget.backup.organization.snapshot.folders.length,
                  ]),
                ),
                (
                  context.tr('相册记录'),
                  d != null
                      ? context.tr('{0} 个', [d.albums.length])
                      : widget.backup.albumCount == null
                      ? context.tr('正在核对或暂不可用')
                      : context.tr('{0} 个', [widget.backup.albumCount]),
                ),
                (context.tr('图片收藏'), context.tr('{0} 条', [images])),
                (context.tr('视频收藏'), context.tr('{0} 条', [videos])),
                (
                  context.tr('待处理收藏'),
                  context.tr('{0} 条', [
                    _result?.pendingFavorites ?? snapshot.pending.length,
                  ]),
                ),
              ]),
              if (d != null) ...[
                BackupNotice(
                  context.tr('缺少跨设备匹配资料 {0} 条。{1}', [
                    d.unresolvedCount,
                    d.unresolvedCount == 0
                        ? context.tr('跨设备匹配资料已保存。')
                        : context.tr('记录已保存，换设备时可能需要手动关联。'),
                  ]),
                ),
                Text(context.tr('文件已由系统保存到你选择的位置。请妥善保管。')),
              ] else
                BackupNotice(context.tr('只保存分类和 PhotoTree 收藏记录，不包含原始图片或视频。')),
              if (_message != null && d == null)
                BackupNotice(
                  context.tr(_message!, _progress),
                  key: const ValueKey('backup-result'),
                  warning: _failed,
                ),
              if (_busy) const LinearProgressIndicator(),
              if (_busy && _preparing)
                TextButton(
                  onPressed: _stopping
                      ? null
                      : () {
                          widget.backup.stopPreparation();
                          setState(() {
                            _stopping = true;
                            _message =
                                '已请求停止，不再读取下一项。当前读取结束后释放任务；可返回，迟到结果不会保存。';
                          });
                        },
                  child: Text(
                    _stopping ? context.tr('正在停止准备') : context.tr('停止准备'),
                  ),
                ),
              ExpansionTile(
                title: Text(context.tr('文件内容与隐私')),
                children: [
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      context.tr(
                        '包含相册名称、目录路径、顺序和可用匹配资料；不包含原始媒体、缩略图、应用设置或操作历史。\n不会修改系统收藏。读取原始内容仅用于计算大小与指纹；拒绝后仍可保存全部私有记录。',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _export,
                icon: const Icon(Icons.save_alt),
                label: Text(
                  d == null ? context.tr('导出备份') : context.tr('再次导出'),
                ),
              ),
              if (d != null)
                TextButton(
                  onPressed: () => Navigator.maybePop(context),
                  child: Text(context.tr('返回备份与恢复')),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

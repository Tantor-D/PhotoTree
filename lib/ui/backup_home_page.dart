import 'interface_strings.dart';

import 'package:flutter/material.dart';

import '../backup/backup_export.dart';
import '../backup/backup_restore.dart';
import 'backup_page.dart';
import 'restore_page.dart';
import 'backup_widgets.dart';
import 'visual_style.dart';

class BackupHomePage extends StatelessWidget {
  const BackupHomePage({
    super.key,
    required this.backup,
    required this.restore,
  });
  final BackupExport backup;
  final BackupRestore restore;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      restore,
      restore.favorites,
      restore.organization,
    ]),
    builder: (context, _) {
      final albums = restore.organization.snapshot.descriptors.values
          .where((a) => a.pending)
          .length;
      final favorites = restore.favorites.snapshot.pending.length;
      void open(Widget page) =>
          Navigator.of(context)
              .push<void>(MaterialPageRoute(builder: (_) => page));
      Widget task(
        String title,
        String subtitle,
        IconData icon,
        VoidCallback? action,
      ) => Card(
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          minVerticalPadding: 16,
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: action,
        ),
      );
      return Scaffold(
        appBar: photoTreePageBar(context, title: context.tr('备份与恢复')),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                context.tr('保护你的整理成果'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              BackupNotice(context.tr('保存相册分类与 PhotoTree 收藏。原始图片和视频需要另行备份。')),
              if (restore.blocked) ...[
                BackupNotice(
                  restore.status ?? context.tr('私有数据恢复受阻；记录已保留。'),
                  warning: true,
                ),
                FilledButton(
                  onPressed: restore.busy
                      ? null
                      : () => open(RestorePage(restore: restore)),
                  child: Text(context.tr('查看并重试恢复')),
                ),
              ] else ...[
                task(
                  context.tr('导出备份'),
                  context.tr('保存当前分类与应用内收藏'),
                  Icons.save_alt,
                  restore.busy ? null : () => open(BackupPage(backup: backup)),
                ),
                task(
                  context.tr('从备份恢复'),
                  context.tr('选择文件，核对后替换当前应用数据'),
                  Icons.restore,
                  restore.busy
                      ? null
                      : () => open(RestorePage(restore: restore)),
                ),
                const SizedBox(height: 16),
                task(
                  context.tr('处理待关联记录'),
                  albums + favorites == 0
                      ? context.tr('暂无待处理记录')
                      : context.tr('{0} 个相册 · {1} 条收藏待关联', [albums, favorites]),
                  Icons.link,
                  restore.busy
                      ? null
                      : () => open(
                          RestorePage(
                            restore: restore,
                            intent: RestoreIntent.pending,
                          ),
                        ),
                ),
                task(
                  context.tr('回滚私有数据'),
                  restore.hasRollback
                      ? context.tr('查看最近一次私有恢复或关联操作前的副本')
                      : context.tr('暂无副本；成功恢复或关联后可用'),
                  Icons.history,
                  restore.busy || !restore.hasRollback
                      ? null
                      : () => open(
                          RestorePage(
                            restore: restore,
                            intent: RestoreIntent.rollback,
                          ),
                        ),
                ),
              ],
              ExpansionTile(
                title: Text(context.tr('备份保护哪些内容？')),
                children: [
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      context.tr(
                        '包含相册文件夹、分类关系、顺序、相册映射及应用内收藏记录。\n不包含原始媒体、应用设置或真实操作历史；恢复与回滚不撤销文件移动或删除，也不修改系统相册收藏。',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

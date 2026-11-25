import 'interface_strings.dart';

import 'package:flutter/material.dart';

import 'visual_style.dart';

import '../storage/directory_access.dart';

class DirectoryAccessPage extends StatefulWidget {
  const DirectoryAccessPage({
    super.key,
    required this.directory,
    required this.access,
  });
  final DirectoryIdentity directory;
  final DirectoryAccess access;
  @override
  State<DirectoryAccessPage> createState() => _DirectoryAccessPageState();
}

class _DirectoryAccessPageState extends State<DirectoryAccessPage>
    with WidgetsBindingObserver {
  DirectoryCapabilities? _capabilities;
  String? _message;
  bool _busy = false;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _epoch++;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _check();
    if (state == AppLifecycleState.inactive && !_busy) {
      _epoch++;
      setState(() => _capabilities = null);
    }
  }

  Future<void> _check() async {
    final epoch = ++_epoch;
    setState(() => _capabilities = null);
    final answer = await widget.access.inspect(widget.directory);
    if (mounted && epoch == _epoch) setState(() => _capabilities = answer);
  }

  Future<void> _authorize() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final answer = await widget.access.authorize(widget.directory);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = switch (answer) {
        DirectoryRequest.granted => '授权已保存，正在重新核对目录',
        DirectoryRequest.cancelled => '已取消授权，未更改媒体',
        DirectoryRequest.rejected => '所选目录不匹配或不受支持；请选择下方完整路径对应的目录',
        DirectoryRequest.busy => '另一个文件选择操作进行中，请完成后重试',
        DirectoryRequest.interrupted => '授权未完成，请重新选择目录',
      };
    });
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    final c = _capabilities;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final available = c?.status == DirectoryStatus.available;
    final title = switch (c?.status) {
      DirectoryStatus.available => context.tr('目录已授权'),
      DirectoryStatus.needsAuthorization => context.tr('需要目录授权'),
      DirectoryStatus.revoked => context.tr('授权已失效'),
      DirectoryStatus.unavailable => context.tr('目录暂不可用'),
      DirectoryStatus.unsupported => context.tr('不支持此目录'),
      null => context.tr('正在核对目录…'),
    };
    final parts = widget.directory.path.split('/').where((p) => p.isNotEmpty);
    final name = parts.isEmpty ? widget.directory.path : parts.last;
    final statusColor = available
        ? (theme.brightness == Brightness.dark
              ? const Color(0xFF8DDBA5)
              : const Color(0xFF27633C))
        : colors.onSurfaceVariant;
    return Scaffold(
      appBar: photoTreePageBar(context, title: context.tr('相册目录权限')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
          children: [
            GlassSurface(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.primaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Icon(
                              Icons.folder_outlined,
                              color: colors.onPrimaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(name, style: theme.textTheme.titleMedium),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(context.tr('主共享存储'), style: theme.textTheme.bodySmall),
                    const SizedBox(height: 4),
                    Text(
                      widget.directory.path,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          available
                              ? Icons.check_circle_outline
                              : Icons.info_outline,
                          color: statusColor,
                          size: 22,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: statusColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (c == null)
                      const LinearProgressIndicator()
                    else ...[
                      if (!available) ...[
                        Text(
                          context.domainText(c.reason),
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                      ],
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          _capability(context, context.tr('读取'), c.readable),
                          _capability(context, context.tr('列举'), c.listable),
                        ],
                      ),
                    ],
                    if (_message != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          context.domainText(_message!),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy || !widget.directory.supported
                  ? null
                  : _authorize,
              icon: const Icon(Icons.folder_open_outlined, size: 20),
              label: Text(
                _busy
                    ? context.tr('正在等待授权…')
                    : available
                    ? context.tr('重新授权目录')
                    : context.tr('选择目录授权'),
              ),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _check,
              icon: const Icon(Icons.refresh, size: 20),
              label: Text(context.tr('重新核对')),
            ),
            const SizedBox(height: 8),
            Text(
              context.tr('授权仅用于访问此目录，不改变相册分类。'),
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 4),
              childrenPadding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              shape: const Border(),
              collapsedShape: const Border(),
              title: Text(
                context.tr('权限说明'),
                style: theme.textTheme.titleSmall,
              ),
              children: [
                Text(
                  context.tr('请选择与上方路径完全一致的本地目录。'),
                  style: theme.textTheme.bodySmall,
                ),
                if (available) ...[
                  const SizedBox(height: 8),
                  Text(
                    context.domainText(c!.reason),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  context.tr('创建、移动和删除时仍会重新核对权限与实际内容。授权成功不代表操作已完成。'),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _capability(BuildContext context, String label, bool available) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(
          '$label：${available ? context.tr('可用') : context.tr('不可用')}',
          style: theme.textTheme.bodySmall,
        ),
      ),
    );
  }
}

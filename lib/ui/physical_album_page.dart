import 'interface_strings.dart';

import 'package:flutter/material.dart';

import 'visual_style.dart';

import 'dialog_action_bar.dart';

import '../organization/album_creation.dart';
import '../organization/organization.dart';
import '../storage/directory_access.dart';

Future<DirectoryIdentity?> chooseExistingDirectory(
  BuildContext context,
  Organization organization, {
  String initial = 'Pictures/',
}) => Navigator.of(context).push<DirectoryIdentity>(
  MaterialPageRoute(
    builder: (_) => _DirectorySelectionPage(
      access: organization.directories!,
      initial: initial,
    ),
  ),
);

class _DirectorySelectionPage extends StatefulWidget {
  const _DirectorySelectionPage({required this.access, required this.initial});
  final PhysicalDirectoryAccess access;
  final String initial;
  @override
  State<_DirectorySelectionPage> createState() => _DirectorySelectionState();
}

class _DirectorySelectionState extends State<_DirectorySelectionPage> {
  late final path = TextEditingController(text: widget.initial);
  bool busy = false;
  String? message;
  @override
  void dispose() {
    path.dispose();
    super.dispose();
  }

  Future<void> select() async {
    var value = path.text.trim();
    if (!value.endsWith('/')) value += '/';
    final directory = DirectoryIdentity('external_primary', value);
    if (!directory.supported) {
      setState(() => message = '请输入 Pictures/ 或 DCIM/ 内的完整目录路径');
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    final request = await widget.access.authorize(directory);
    if (!mounted) return;
    if (request != DirectoryRequest.granted) {
      setState(() {
        busy = false;
        message = request == DirectoryRequest.cancelled
            ? '已取消，没有更改媒体'
            : '所选目录不匹配或授权未完成，请重试';
      });
      return;
    }
    final read = await widget.access.readDirectory(directory);
    if (!mounted) return;
    if (!read.verified) {
      setState(() {
        busy = false;
        message = read.reason;
      });
      return;
    }
    Navigator.pop(context, directory);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: photoTreePageBar(context, title: context.tr('选择真实目录')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            context.tr(
              '主共享存储 · Pictures/ 或 DCIM/\n填写实际目录路径，然后在系统选择器中选中同一目录。此步骤只授权和核对，不创建目录。',
            ),
          ),
          TextField(
            controller: path,
            enabled: !busy,
            decoration: InputDecoration(
              labelText: context.tr('实际目录路径'),
              hintText: context.tr('Pictures/旅行/'),
            ),
          ),
          if (message != null) Text(context.domainText(message!)),
          if (busy) const LinearProgressIndicator(),
          FilledButton(
            onPressed: busy ? null : select,
            child: Text(context.tr('打开系统选择器并授权')),
          ),
        ],
      ),
    ),
  );
}

class PhysicalAlbumPage extends StatefulWidget {
  const PhysicalAlbumPage({
    super.key,
    required this.organization,
    required this.parent,
    this.onCreated,
  });
  final Organization organization;
  final String parent;
  final ValueChanged<String>? onCreated;
  @override
  State<PhysicalAlbumPage> createState() => _PhysicalAlbumState();
}

class _PhysicalAlbumState extends State<PhysicalAlbumPage> {
  final name = TextEditingController();
  DirectoryIdentity? directory;
  bool busy = false;
  String? message;
  Organization get org => widget.organization;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> choose() async {
    final selected = await chooseExistingDirectory(
      context,
      org,
      initial: directory?.path ?? 'Pictures/',
    );
    if (mounted && selected != null) setState(() => directory = selected);
  }

  Future<void> create() async {
    if (directory == null) return;
    setState(() {
      busy = true;
      message = null;
    });
    final previousIds = org.creations.map((record) => record.id).toSet();
    final error = await org.createAlbum(widget.parent, directory!, name.text);
    if (!mounted) return;
    setState(() {
      busy = false;
      message = error;
    });
    if (error == null) {
      final created = org.creations
          .where(
            (record) =>
                !previousIds.contains(record.id) &&
                record.outcome == CreationOutcome.completed,
          )
          .toList();
      if (created.length == 1) widget.onCreated?.call(created.single.key);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.tr('真实相册已建立'))));
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = org.snapshot;
    final parent = snapshot.exists(widget.parent)
        ? snapshot
              .path(widget.parent)
              .map(
                (id) => id == rootFolder
                    ? context.tr('根目录')
                    : snapshot.folders[id]!.name,
              )
              .join(' / ')
        : context.tr('原相册文件夹已不存在');
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: photoTreePageBar(context, title: context.tr('新建相册')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(context.tr('应用内归属：{0}', [parent])),
            const SizedBox(height: 16),
            Text(
              context.tr('真实父目录：{0}', [directory?.path ?? context.tr('尚未选择')]),
            ),
            TextButton(
              onPressed: busy ? null : choose,
              child: Text(context.tr('选择真实父目录')),
            ),
            TextField(
              controller: name,
              // Preserve pasted/IME newlines for explicit domain rejection;
              // single-line input silently strips them before validation.
              minLines: 1,
              maxLines: 2,
              textInputAction: TextInputAction.done,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: context.tr('新相册名称（1–64 个字符）'),
              ),
            ),
            Text(context.tr('只创建这一个真实目录。同名文件或目录会拒绝，不合并、不自动改名。系统图库可能不显示空目录。')),
            if (message != null) Text(context.domainText(message!)),
            if (busy) const LinearProgressIndicator(),
            FilledButton(
              onPressed: busy || directory == null ? null : create,
              child: Text(context.tr('确认建立真实相册')),
            ),
            if (busy)
              TextButton(
                onPressed: () {
                  org.cancelCreation();
                  setState(() => message = '已请求停止；已提交的创建仍会核对');
                },
                child: Text(context.tr('停止尚未开始的创建')),
              ),
            if (org.creations.any((r) => r.unresolved))
              TextButton(
                onPressed: busy
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => CreationReviewPage(organization: org),
                        ),
                      ),
                child: Text(context.tr('处理未完成的创建')),
              ),
          ],
        ),
      ),
    );
  }
}

class CreationReviewPage extends StatefulWidget {
  const CreationReviewPage({super.key, required this.organization});
  final Organization organization;
  @override
  State<CreationReviewPage> createState() => _CreationReviewState();
}

class _CreationReviewState extends State<CreationReviewPage> {
  Organization get org => widget.organization;
  String? message;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    org.addListener(changed);
  }

  @override
  void dispose() {
    org.removeListener(changed);
    super.dispose();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> run(Future<String?> Function() action) async {
    setState(() {
      busy = true;
      message = null;
    });
    final result = await action();
    if (mounted) {
      setState(() {
        busy = false;
        message = result;
      });
    }
  }

  Future<void> associate(AlbumCreationRecord record) async {
    final directory = await chooseExistingDirectory(
      context,
      org,
      initial: record.directory,
    );
    if (!mounted || directory == null) return;
    final snapshot = org.snapshot;
    final parent = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        insetPadding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 400),
        titleTextStyle: Theme.of(context).textTheme.titleLarge,
        title: Text(context.tr('选择新的应用内归属')),
        children: [
          for (final id in [rootFolder, ...snapshot.folders.keys])
            SimpleDialogOption(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              onPressed: () => Navigator.pop(context, id),
              child: Text(
                snapshot
                    .path(id)
                    .map(
                      (key) => key == rootFolder
                          ? context.tr('根目录')
                          : snapshot.folders[key]!.name,
                    )
                    .join(' / '),
              ),
            ),
        ],
      ),
    );
    if (!mounted || parent == null) return;
    await run(
      () => org.resolveAlbumCreation(
        record.id,
        existing: directory,
        parent: parent,
      ),
    );
  }

  Future<void> dismiss(AlbumCreationRecord record) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => PhotoTreeConfirmation(
        title: Text(context.tr('不再处理此记录？')),
        content: Text(context.tr('结束跟进，不删除任何目录或媒体。上次创建结果仍记为未知，历史会保留。')),
        dismissLabel: context.tr('取消'),
        onDismiss: () => Navigator.pop(context, false),
        actionLabel: context.tr('结束跟进'),
        onAction: () => Navigator.pop(context, true),
      ),
    );
    if (mounted && yes == true) {
      await run(() => org.resolveAlbumCreation(record.id));
    }
  }

  String label(AlbumCreationRecord r) {
    if (r.resolution == CreationResolution.associated) {
      return context.tr('历史创建结果未知 · 已按新选择归类现有目录');
    }
    if (r.resolution == CreationResolution.dismissed) {
      return context.tr('历史创建结果未知 · 已结束跟进');
    }
    return switch (r.outcome) {
      CreationOutcome.completed => context.tr('创建和归类已完成'),
      CreationOutcome.conflict => context.tr('同名冲突 · 未创建'),
      CreationOutcome.failed => context.tr('创建失败'),
      CreationOutcome.cancelled => context.tr('已取消 · 未创建'),
      CreationOutcome.created when org.canRetryCreation(r.id) => context.tr(
        '目录已建立，归类待完成',
      ),
      _ => context.tr('无法确认上次创建结果'),
    };
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: photoTreePageBar(context, title: context.tr('相册创建记录')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            context.tr('应用重开不会再次创建目录。重新归类只建立新的私有关联，不会认定历史创建成功。未处理记录会暂停备份和恢复。'),
          ),
          if (message != null) Text(context.domainText(message!)),
          if (busy || org.busy) const LinearProgressIndicator(),
          for (final record in org.creations.reversed)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(record.directory),
                    Text(label(record)),
                    if (record.unresolved) ...[
                      if (org.canRetryCreation(record.id))
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => run(
                                  () => org.retryAlbumCreation(record.id),
                                ),
                          child: Text(context.tr('核对并补齐归类（不再创建）')),
                        ),
                      TextButton(
                        onPressed: busy ? null : () => associate(record),
                        child: Text(context.tr('重新核对并归类现有目录')),
                      ),
                      TextButton(
                        onPressed: busy ? null : () => dismiss(record),
                        child: Text(context.tr('不再处理')),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          if (org.creations.isEmpty) Text(context.tr('暂无创建记录')),
        ],
      ),
    ),
  );
}

class CreationBlockNotice extends StatelessWidget {
  const CreationBlockNotice({super.key, required this.organization});
  final Organization organization;
  @override
  Widget build(BuildContext context) => organization.creationIssue == null
      ? const SizedBox.shrink()
      : ListTile(
          title: Text(context.domainText(organization.creationIssue!)),
          trailing: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CreationReviewPage(organization: organization),
              ),
            ),
            child: Text(context.tr('处理记录')),
          ),
        );
}

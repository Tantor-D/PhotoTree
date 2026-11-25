import 'interface_strings.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../media/browser.dart';
import '../organization/organization.dart';
import 'album_tree_row.dart';
import 'visual_style.dart';

/// Selects a private organization container; never a physical media destination.
class FolderTargetPicker extends StatefulWidget {
  const FolderTargetPicker({
    super.key,
    required this.organization,
    required this.currentParent,
    required this.movingName,
    this.movingFolderId,
  });
  final Organization organization;
  final String currentParent, movingName;
  final String? movingFolderId;

  @override
  State<FolderTargetPicker> createState() => _FolderTargetPickerState();
}

class _FolderTargetPickerState extends State<FolderTargetPicker> {
  Organization get org => widget.organization;
  late final _snapshot = org.snapshot;
  late final _generation = org.browser.generation;
  late final _directoryRevision = org.directoryRevision;
  late final _expanded = {..._snapshot.path(widget.currentParent), rootFolder};
  String? _selected;

  bool get ready =>
      org.phase == OrganizationPhase.ready &&
      (widget.movingFolderId != null ||
          org.browser.phase == BrowsePhase.ready) &&
      !org.busy &&
      !org.operationGuard.held &&
      identical(_snapshot, org.snapshot) &&
      _generation == org.browser.generation &&
      _directoryRevision == org.directoryRevision;

  String label(String id) =>
      id == rootFolder ? context.tr('根目录') : _snapshot.folders[id]!.name;
  String? disabledReason(String id) {
    if (id == widget.currentParent) return context.tr('当前位置');
    if (widget.movingFolderId != null &&
        _snapshot.includes(widget.movingFolderId!, id)) {
      return id == widget.movingFolderId
          ? context.tr('不能移到自身')
          : context.tr('不能移到后代文件夹');
    }
    return null;
  }

  List<Widget> rows(String id, int depth) {
    final children = _snapshot.children(id);
    final reason = disabledReason(id);
    return [
      Padding(
        padding: EdgeInsets.only(left: math.min(depth * 14.0, 56)),
        child: AlbumTreeRow(
          key: ValueKey('target-$id'),
          leading: const Icon(Icons.folder_outlined),
          title: label(id),
          subtitle: reason,
          selected: _selected == id && ready,
          enabled: ready && reason == null,
          // Expansion remains available even if this row cannot be a target.
          onTap: ready && reason == null
              ? () => setState(() => _selected = id)
              : null,
          trailing: children.isEmpty
              ? null
              : IconButton(
                  key: ValueKey('expand-target-$id'),
                  tooltip:
                      '${_expanded.contains(id) ? context.tr('收起') : context.tr('展开')} ${label(id)}',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: ready
                      ? () => setState(() {
                          if (!_expanded.add(id)) _expanded.remove(id);
                        })
                      : null,
                  icon: Icon(
                    _expanded.contains(id)
                        ? Icons.expand_more
                        : Icons.chevron_right,
                  ),
                ),
        ),
      ),
      if (_expanded.contains(id))
        for (final child in children) ...rows(child.id, depth + 1),
    ];
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([org, org.browser]),
    builder: (context, _) {
      final media = MediaQuery.of(context);
      final height =
          math.max(
            0.0,
            media.size.height -
                media.padding.vertical -
                media.viewInsets.vertical -
                24,
          ) *
          .85;
      final valid =
          ready && _selected != null && disabledReason(_selected!) == null;
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 400),
        child: GlassSurface(
          highOpacity: true,
          borderRadius: PhotoTreeStyle.panelRadius,
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Expanded(
                    child: ListView(
                      key: const ValueKey('target-folder-tree'),
                      children: [
                        Text(
                          context.tr('移到相册文件夹'),
                          style: TextStyle(
                            fontSize: 19,
                            height: 26 / 19,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(widget.movingName),
                        Text(
                          context.tr('只改变应用内分类，不移动手机文件'),
                          style: TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 12),
                        if (!ready) Text(context.tr('归类目标或来源已变化，请取消后重新选择')),
                        ...rows(rootFolder, 0),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: height * .22),
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: SizedBox(
                          width: double.infinity,
                          child: Text(
                            !ready
                                ? context.tr('原目标已不可用')
                                : _selected == null
                                ? context.tr('当前目标：尚未选择')
                                : context.tr('当前目标：{0}', [
                                    _snapshot
                                        .path(_selected!)
                                        .map(label)
                                        .join(' / '),
                                  ]),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: () => Navigator.pop(context),
                          child: Text(context.tr('取消')),
                        ),
                      ),
                      Expanded(
                        child: FilledButton(
                          key: const ValueKey('use-target-folder'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: valid
                              ? () {
                                  if (ready &&
                                      _selected != null &&
                                      disabledReason(_selected!) == null) {
                                    Navigator.pop(context, _selected);
                                  } else {
                                    setState(() {});
                                  }
                                }
                              : null,
                          child: Text(context.tr('移到此文件夹')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

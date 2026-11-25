import 'interface_strings.dart';

import 'package:flutter/material.dart';

import 'visual_style.dart';

import '../media/browser.dart';
import '../organization/organization.dart';
import 'album_folders.dart' show albumDirectoryLabel;

// Only this page owns the draft. Confirmed order remains with Organization.
class OrganizationOrderPage extends StatefulWidget {
  const OrganizationOrderPage({
    super.key,
    required this.organization,
    required this.browser,
    required this.parent,
  });
  final Organization organization;
  final PhotoBrowser browser;
  final String parent;
  @override
  State<OrganizationOrderPage> createState() => _OrganizationOrderPageState();
}

class _OrganizationOrderPageState extends State<OrganizationOrderPage> {
  late final base = widget.organization.snapshot;
  late final generation = widget.browser.generation;
  late final directoryRevision = widget.organization.directoryRevision;
  late final folders = base.children(widget.parent).map((f) => f.id).toList();
  late final visible = base.albums(widget.parent, widget.organization.albums);
  late final albums = visible.map((a) => a.key).toList();
  bool busy = false;
  String? error;
  bool get stale =>
      !identical(base, widget.organization.snapshot) ||
      widget.browser.generation != generation ||
      widget.organization.directoryRevision != directoryRevision ||
      widget.organization.phase != OrganizationPhase.ready;

  @override
  void initState() {
    super.initState();
    // Freeze the lazy fields now, before either source can change.
    folders;
    albums;
    generation;
    directoryRevision;
    widget.organization.addListener(changed);
    widget.browser.addListener(changed);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.organization.removeListener(changed);
    widget.browser.removeListener(changed);
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    final result = await widget.organization.saveOrder(
      parent: widget.parent,
      base: base,
      generation: generation,
      folders: folders,
      albums: albums,
      directoryRevision: directoryRevision,
    );
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    if (result == null) {
      // Allow PopScope to rebuild before the committed page exits.
      setState(() => busy = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.pop(context);
        }
      });
    } else {
      setState(() {
        busy = false;
        error = result;
      });
    }
  }

  Widget section(
    String title,
    List<String> keys,
    String Function(String) label, {
    bool showDirectory = false,
  }) {
    if (keys.isEmpty) return const SliverToBoxAdapter();
    void move(int oldIndex, int newIndex) {
      if (busy || stale) return;
      setState(() => keys.insert(newIndex, keys.removeAt(oldIndex)));
    }

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(title),
          ),
        ),
        SliverReorderableList(
          onReorderItem: move,
          itemCount: keys.length,
          itemBuilder: (context, i) => Material(
            key: ValueKey('order-${keys[i]}'),
            child: ListTile(
              dense: true,
              leading: Icon(
                showDirectory
                    ? Icons.photo_album_outlined
                    : Icons.folder_outlined,
              ),
              title: Text(label(keys[i])),
              subtitle:
                  showDirectory &&
                      albumDirectoryLabel(
                        visible.firstWhere((a) => a.key == keys[i]),
                        visible,
                      ).isNotEmpty
                  ? Text(
                      albumDirectoryLabel(
                        visible.firstWhere((a) => a.key == keys[i]),
                        visible,
                      ).replaceFirst(RegExp(r' · $'), ''),
                    )
                  : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PopupMenuButton<int>(
                    tooltip: context.tr('调整 {0}', [label(keys[i])]),
                    enabled: !busy && !stale,
                    onSelected: (delta) => move(i, i + delta),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: -1,
                        enabled: i > 0,
                        child: Text(context.tr('上移')),
                      ),
                      PopupMenuItem(
                        value: 1,
                        enabled: i + 1 < keys.length,
                        child: Text(context.tr('下移')),
                      ),
                    ],
                  ),
                  ReorderableDelayedDragStartListener(
                    index: i,
                    enabled: !busy && !stale,
                    child: Semantics(
                      label: context.tr('长按拖动 {0}', [label(keys[i])]),
                      child: const ColoredBox(
                        color: Colors.transparent,
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: Icon(Icons.drag_handle),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !busy,
    child: Scaffold(
      appBar: photoTreePageBar(
        context,
        title: context.tr('调整顺序'),
        leading: TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: Text(context.tr('取消')),
        ),
        actions: [
          TextButton(
            onPressed: busy || stale ? null : save,
            child: Text(busy ? context.tr('保存中…') : context.tr('保存')),
          ),
        ],
      ),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(context.tr('长按右侧拖动排序')),
              ),
            ),
            if (error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(context.domainText(error!)),
                ),
              ),
            if (stale && !busy)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(context.tr('顺序草稿已过期，请取消并重新调整')),
                ),
              ),
            section(
              context.tr('相册文件夹'),
              folders,
              (id) => base.folders[id]!.name,
            ),
            // Permission changes must not leave old accessible album content on screen.
            if (!stale || busy && widget.browser.generation == generation)
              section(
                context.tr('相册'),
                albums,
                (key) =>
                    context.albumName(visible.firstWhere((a) => a.key == key)),
                showDirectory: true,
              ),
          ],
        ),
      ),
    ),
  );
}

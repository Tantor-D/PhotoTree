import 'interface_strings.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../media/browser.dart';
import '../media/media_source.dart';
import '../organization/organization.dart';
import 'album_tree_row.dart';
import 'photo_grid.dart';
import 'visual_style.dart';

/// Transient selection only. Organization remains the sole tree owner.
class AlbumTargetPicker extends StatefulWidget {
  const AlbumTargetPicker({
    super.key,
    required this.organization,
    required this.canSelect,
    this.initialAlbumKey,
    this.disabledReason,
  });
  final Organization organization;
  final bool Function(Album) canSelect;
  final String Function(Album)? disabledReason;
  final String? initialAlbumKey;
  @override
  State<AlbumTargetPicker> createState() => _AlbumTargetPickerState();
}

class _AlbumTargetPickerState extends State<AlbumTargetPicker> {
  final _expanded = <String>{};
  String? _selected;
  Organization get org => widget.organization;
  @override
  void initState() {
    super.initState();
    _selected = widget.initialAlbumKey;
    if (_selected != null) {
      _expanded.addAll(
        org.snapshot.path(org.snapshot.parentOfAlbum(_selected!)),
      );
    }
  }

  bool get ready =>
      org.phase == OrganizationPhase.ready &&
      org.browser.phase == BrowsePhase.ready;
  Album? selected(List<Album> albums) {
    for (final album in albums) {
      if (album.key == _selected && ready && widget.canSelect(album)) {
        return album;
      }
    }
    return null;
  }

  String path(Album album) => [
    ...org.snapshot
        .path(org.snapshot.parentOfAlbum(album.key))
        .map(
          (id) => id == rootFolder
              ? context.tr('根目录')
              : org.snapshot.folders[id]!.name,
        ),
    context.albumName(album),
  ].join(' / ');
  List<Widget> rows(String parent, int depth, List<Album> albums) {
    Widget indent(Widget child) => Padding(
      padding: EdgeInsets.only(left: math.min(depth * 14.0, 56)),
      child: child,
    );
    return [
      for (final folder in org.snapshot.children(parent)) ...[
        indent(
          AlbumTreeRow(
            key: ValueKey('target-folder-${folder.id}'),
            leading: const Icon(Icons.folder_outlined),
            title: folder.name,
            trailing: Icon(
              _expanded.contains(folder.id)
                  ? Icons.expand_more
                  : Icons.chevron_right,
            ),
            onTap: () => setState(() {
              if (!_expanded.add(folder.id)) _expanded.remove(folder.id);
            }),
          ),
        ),
        if (_expanded.contains(folder.id))
          ...rows(folder.id, depth + 1, albums),
      ],
      for (final album in org.snapshot.albums(parent, albums))
        indent(
          AlbumTreeRow(
            key: ValueKey('target-album-${album.key}'),
            leading: SizedBox(
              width: 32,
              height: 32,
              child: album.photos.isEmpty
                  ? const Icon(Icons.photo_album_outlined)
                  : PhotoTile(
                      key: ValueKey(
                        '${org.browser.imageGeneration}:${album.photos.first.key}',
                      ),
                      browser: org.browser,
                      photo: album.photos.first,
                      size: 32,
                    ),
            ),
            title: context.albumName(album),
            subtitle: widget.canSelect(album)
                ? (albums.where((a) => a.name == album.name).length > 1
                      ? album.directory
                      : null)
                : widget.disabledReason?.call(album) ??
                      (album.status == null
                          ? null
                          : context.domainText(album.status!)) ??
                      context.tr('此相册暂不可作为移动目标'),
            selected: _selected == album.key && widget.canSelect(album),
            enabled: ready && widget.canSelect(album),
            trailing: widget.canSelect(album)
                ? Text('${album.photos.length}')
                : null,
            onTap: ready && widget.canSelect(album)
                ? () => setState(() => _selected = album.key)
                : null,
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([org, org.browser]),
    builder: (context, _) {
      final albums = org.albums;
      final current = selected(albums);
      final media = MediaQuery.of(context);
      final available = math.max(
        0.0,
        media.size.height - media.padding.vertical - media.viewInsets.vertical,
      );
      final height = available * .85;
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        constraints: BoxConstraints(
          maxWidth: math.min(400, media.size.width - 24),
          maxHeight: height,
        ),
        clipBehavior: Clip.antiAlias,
        child: GlassSurface(
          highOpacity: true,
          borderRadius: PhotoTreeStyle.panelRadius,
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: height * .19),
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          context.tr('选择目标相册'),
                          style: TextStyle(
                            fontSize: 19,
                            height: 26 / 19,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      key: const ValueKey('target-album-tree'),
                      children: [
                        Text(
                          context.tr('相册文件夹仅用于导航，请选择一个相册'),
                          style: TextStyle(fontSize: 12),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text(context.tr('根目录')),
                        ),
                        if (!ready) Text(context.tr('媒体或组织正在更新，请等待核对')),
                        if (ready) ...rows(rootFolder, 0, albums),
                        if (ready && !albums.any(widget.canSelect))
                          Text(context.tr('暂无可选择的真实相册')),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: height * .23),
                    child: SingleChildScrollView(
                      child: SizedBox(
                        width: double.infinity,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                current == null
                                    ? (_selected == null
                                          ? context.tr('当前目标：尚未选择')
                                          : context.tr('原目标已不可用，请重新选择'))
                                    : context.tr('当前目标：{0}', [
                                        context.albumName(current),
                                      ]),
                              ),
                              if (current != null) ...[
                                Text(path(current)),
                                Text(current.directory),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(context.tr('取消')),
                        ),
                      ),
                      Expanded(
                        child: FilledButton(
                          key: const ValueKey('use-target-album'),
                          onPressed: current == null
                              ? null
                              : () {
                                  final latest = selected(org.albums);
                                  if (latest != null) {
                                    Navigator.pop(context, latest.key);
                                  }
                                },
                          child: Text(context.tr('使用此相册')),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

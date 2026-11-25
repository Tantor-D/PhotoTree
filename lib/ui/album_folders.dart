import 'interface_strings.dart';
import 'folder_target_picker.dart';
import 'album_tree_row.dart';
import '../library/physical_operations.dart';
import 'physical_operations_page.dart';
import 'directory_access_page.dart';
import 'physical_album_page.dart';
import '../storage/directory_access.dart';

import 'package:flutter/material.dart';

import 'dialog_action_bar.dart';

import 'package:flutter/foundation.dart';

import '../library/views.dart';
import '../library/favorites.dart';
import '../media/browser.dart';
import '../media/media_source.dart';
import '../organization/organization.dart';
import 'photo_grid.dart';
import 'visual_style.dart';

import 'dart:math' as math;

import 'package:flutter/scheduler.dart';

class AlbumFoldersPage extends StatefulWidget {
  const AlbumFoldersPage({
    super.key,
    required this.organization,
    required this.browser,
    required this.selectedView,
    required this.selectedAlbumKey,
    required this.onViewSelected,
    required this.onAlbumSelected,
    required this.contentBuilder,
    required this.opacity,
    required this.onOpacityChanged,
    required this.onOpacityChangeEnd,
    required this.onOpacityReset,
    required this.opacityStatus,
    required this.retryOpacity,
    this.favorites,
    this.physical,
    this.directoryAccess,
  });
  final Organization organization;
  final PhotoBrowser browser;
  final Favorites? favorites;
  final PhysicalOperations? physical;
  final DirectoryAccess? directoryAccess;
  final LibraryView selectedView;
  final String? selectedAlbumKey;
  final ValueChanged<LibraryView> onViewSelected;
  final ValueChanged<String?> onAlbumSelected;
  final Widget Function(BuildContext, VoidCallback, VoidCallback, bool)
  contentBuilder;
  final ValueListenable<int?> opacity;
  final ValueChanged<int> onOpacityChanged;
  final VoidCallback onOpacityChangeEnd, onOpacityReset;
  final ValueListenable<({String? message, bool canRetry})> opacityStatus;
  final VoidCallback retryOpacity;
  @override
  State<AlbumFoldersPage> createState() => _AlbumFoldersPageState();
}

class _AlbumFoldersPageState extends State<AlbumFoldersPage>
    with TickerProviderStateMixin {
  String _current = rootFolder;
  List<String> _lastPath = [rootFolder];
  bool _expanded = false;
  bool _appearanceExpanded = false;
  final Set<String> _openFolders = {};
  final _scroll = ScrollController();
  final _listKey = GlobalKey();
  final _createdRowKey = GlobalKey();
  String? _createdRowId;
  int _revealTicket = 0;
  final _targetKeys = <String, GlobalKey>{};
  _AlbumDrag? _drag;
  _AlbumDrag? _menuSource;
  final _hover = ValueNotifier<String?>(null);
  late final AnimationController _panelMotion;
  late final Ticker _edgeTicker;
  Duration _lastEdgeTick = Duration.zero;
  double _closeDistance = 0;
  Offset? _pointer;
  double _panelOffset = 0;

  Organization get org => widget.organization;
  PhotoBrowser get browser => widget.browser;
  @override
  void initState() {
    super.initState();
    _panelMotion =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
        )..addStatusListener((status) {
          if (status == AnimationStatus.dismissed && mounted) setState(() {});
        });
    _edgeTicker = createTicker((elapsed) {
      final seconds = (elapsed - _lastEdgeTick).inMicroseconds / 1000000;
      _lastEdgeTick = elapsed;
      _scrollEdge(seconds.clamp(0.0, .05));
    });
    _scroll.addListener(() {
      if (_scroll.hasClients) _panelOffset = _scroll.offset;
    });
    org.addListener(_changed);
    browser.addListener(_changed);
    widget.favorites?.addListener(_changed);
  }

  @override
  void dispose() {
    _edgeTicker.dispose();
    _panelMotion.dispose();
    _hover.dispose();
    _scroll.dispose();
    org.removeListener(_changed);
    browser.removeListener(_changed);
    widget.favorites?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    // The source can disappear on permission changes before Draggable sends
    // onDragEnd. Stop the frame ticker as soon as its captured token expires.
    if (_drag != null && !_valid(_drag!)) {
      _edgeTicker.stop();
      _pointer = null;
      _drag = null;
      _hover.value = null;
    }
    setState(() {
      if (!org.snapshot.exists(_current)) {
        _current = _lastPath.reversed.firstWhere(
          org.snapshot.exists,
          orElse: () => rootFolder,
        );
      }
      _lastPath = org.snapshot.path(_current);
    });
  }

  void _setExpanded(bool value) {
    _revealTicket++;
    _endDrag();
    setState(() => _expanded = value);
    if (MediaQuery.disableAnimationsOf(context)) {
      _panelMotion.value = value ? 1 : 0;
    } else if (value) {
      _panelMotion.forward();
    } else {
      _panelMotion.reverse();
    }
    if (value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(
            _panelOffset.clamp(0.0, _scroll.position.maxScrollExtent),
          );
        }
      });
    }
  }

  void _go(String id) => setState(() {
    _current = id;
    _lastPath = org.snapshot.path(id);
  });
  String _label(String id) =>
      id == rootFolder ? context.tr('根目录') : org.snapshot.folders[id]!.name;
  Future<void> _report(Future<String?> operation) async {
    final error = await operation;
    if (!mounted || error == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.domainText(error))));
  }

  Future<void> _revealCreated(String id, String parent) async {
    if (!mounted || !org.snapshot.exists(parent)) return;
    final ticket = ++_revealTicket;
    setState(() {
      _createdRowId = id;
      _openFolders.addAll(org.snapshot.path(parent));
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || ticket != _revealTicket || !_scroll.hasClients) return;
    // Root list children are lazy. Walk existing viewports until the new row
    // is laid out, then use its actual bounds (including enlarged text).
    _scroll.jumpTo(0);
    while (mounted && ticket == _revealTicket && _scroll.hasClients) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || ticket != _revealTicket || !_scroll.hasClients) return;
      final context = _createdRowKey.currentContext;
      if (context != null && context.mounted) {
        await Scrollable.ensureVisible(context, alignment: .5);
        return;
      }
      final next = math.min(
        _scroll.offset + _scroll.position.viewportDimension * .8,
        _scroll.position.maxScrollExtent,
      );
      if (next <= _scroll.offset) return;
      _scroll.jumpTo(next);
    }
  }

  Future<void> _createMenu() async {
    if (!_canEdit()) return;
    var parent = _current;
    var fallback = false;
    while (mounted) {
      final missing = fallback || !org.snapshot.exists(parent);
      fallback = false;
      if (missing) parent = rootFolder;
      final path = org.snapshot.path(parent).map(_label).join(' / ');
      if (!mounted) return;
      final action = await showDialog<String>(
        context: context,
        builder: (context) => _CreationMenu(
          path: path,
          missing: missing,
          canCreateAlbum: org.physicalCreationAvailable,
        ),
      );
      if (!mounted || action == null) return;
      if (action == 'location') {
        final target = await showDialog<String>(
          context: context,
          builder: (context) {
            final snapshot = org.snapshot;
            List<Widget> rows(String id, int depth) => [
              AlbumTreeRow(
                leading: Padding(
                  padding: EdgeInsets.only(
                    left: (depth * 14).clamp(0, 56).toDouble(),
                  ),
                  child: const Icon(Icons.folder_outlined),
                ),
                title: id == rootFolder
                    ? context.tr('根目录')
                    : snapshot.folders[id]!.name,
                subtitle: snapshot
                    .path(id)
                    .map(
                      (key) => key == rootFolder
                          ? context.tr('根目录')
                          : snapshot.folders[key]!.name,
                    )
                    .join(' / '),
                selected: id == parent,
                onTap: () => Navigator.pop(context, id),
              ),
              for (final folder in snapshot.children(id))
                ...rows(folder.id, depth + 1),
            ];
            return AlertDialog(
              title: Text(context.tr('选择创建位置')),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: rows(rootFolder, 0),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(context.tr('取消')),
                ),
              ],
            );
          },
        );
        if (!mounted) return;
        if (target != null) parent = target;
        continue;
      }
      if (!org.snapshot.exists(parent)) {
        parent = rootFolder;
        fallback = true;
        continue;
      }
      if (!_canEdit()) return;
      if (action == 'folder') {
        await _name(inFolder: parent);
      } else {
        _createAlbum(parent);
      }
      return;
    }
  }

  Future<void> _name({AlbumFolder? folder, String? inFolder}) async {
    if (!_canEdit()) return;
    final parent = inFolder ?? _current;
    final parentLabel = org.snapshot.path(parent).map(_label).join(' / ');
    if (folder == null) {
      setState(() => _openFolders.addAll(org.snapshot.path(parent)));
    }
    String? created;
    await showDialog<void>(
      context: context,
      builder: (_) => _FolderNameDialog(
        initial: folder?.name ?? '',
        title: folder == null ? context.tr('新建相册文件夹') : context.tr('重命名相册文件夹'),
        path: parentLabel,
        save: (name) async {
          if (!_editable) return context.tr('另一项操作正在进行，请稍后重试');
          if (folder != null) return org.rename(folder.id, name);
          final before = org.snapshot.folders.keys.toSet();
          final error = await org.create(parent, name);
          if (error == null) {
            final added = org.snapshot
                .children(parent)
                .where((f) => !before.contains(f.id))
                .toList();
            if (added.length == 1) created = added.single.id;
          }
          return error;
        },
      ),
    );
    if (created != null && mounted) await _revealCreated(created!, parent);
  }

  Future<void> _move({AlbumFolder? folder, Album? album}) async {
    if (!_canEdit()) return;
    final generation = browser.generation;
    final snapshot = org.snapshot;
    final directoryRevision = org.directoryRevision;
    final currentParent = folder?.parent ?? snapshot.parentOfAlbum(album!.key);
    final target = await showDialog<String>(
      context: context,
      builder: (context) => FolderTargetPicker(
        organization: org,
        currentParent: currentParent,
        movingName: folder?.name ?? context.albumName(album!),
        movingFolderId: folder?.id,
      ),
    );
    if (!mounted || target == null) return;
    if (!_canEdit()) return;
    if (folder != null && !identical(snapshot, org.snapshot)) {
      _stale();
      return;
    }
    await _report(
      folder != null
          ? org.moveFolder(
              folder.id,
              target,
              base: snapshot,
              expectedParent: folder.parent,
            )
          : org.moveAlbum(
              album!.key,
              target,
              generation: generation,
              base: snapshot,
              expectedParent: currentParent,
              directoryRevision: directoryRevision,
            ),
    );
  }

  Future<void> _delete(AlbumFolder folder) async {
    if (!_canEdit()) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => PhotoTreeConfirmation(
        title: Text(context.tr('删除空相册文件夹')),
        content: Text(
          context.tr('删除“{0}”？只删除应用内分类，不删除手机文件。含子文件夹或已保存相册关系时不能删除。', [
            folder.name,
          ]),
        ),
        dismissLabel: context.tr('取消'),
        onDismiss: () => Navigator.pop(context, false),
        actionLabel: context.tr('删除'),
        onAction: () => Navigator.pop(context, true),
        destructive: true,
      ),
    );
    if (mounted && confirmed == true && _canEdit()) {
      await _report(org.deleteEmpty(folder.id));
    }
  }

  Future<void> _dissolve(AlbumFolder folder) async {
    if (!_canEdit()) return;
    final FolderDissolution preview;
    try {
      preview = org.previewDissolution(folder.id);
    } on OrganizationError catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.domainText(e.message))));
      return;
    }
    final target = preview.base
        .path(preview.target)
        .map(
          (id) => id == rootFolder
              ? context.tr('根目录')
              : preview.base.folders[id]!.name,
        )
        .join(' / ');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => PhotoTreeConfirmation(
        title: Text(context.tr('解散相册文件夹')),
        content: Text(
          context.tr('解散“{0}”？\n', [folder.name]) +
              context.tr('保留相册，移到上一级：{0}\n', [target]) +
              context.tr('直接子文件夹：{0} 个\n', [preview.childFolders]) +
              context.tr('归类相册：{0} 个（其中暂不可见：{1} 个）\n', [
                preview.albums,
                preview.hiddenAlbums,
              ]) +
              context.tr('仅移除应用内分类容器，直接子节点按原顺序追加到父层同类末尾。') +
              context.tr('子文件夹内部关系保留，不删除真实相册、媒体或收藏。'),
        ),
        dismissLabel: context.tr('取消'),
        onDismiss: () => Navigator.pop(context, false),
        actionLabel: context.tr('确认解散'),
        onAction: () => Navigator.pop(context, true),
      ),
    );
    if (mounted && confirmed == true && _canEdit()) {
      await _report(org.dissolve(preview));
    }
  }

  void _openAlbum(Album album) {
    widget.onAlbumSelected(album.key);
    _setExpanded(false);
  }

  bool get _editable =>
      org.phase == OrganizationPhase.ready &&
      !org.busy &&
      !org.operationGuard.held;
  bool _canEdit() {
    if (_editable) return true;
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.tr('另一项操作正在进行，请稍后重试'))));
    }
    return false;
  }

  _AlbumDrag _token(String id, String parent, bool folder) => _AlbumDrag(
    id,
    parent,
    folder,
    org.snapshot,
    browser.generation,
    org.directoryRevision,
  );

  bool _valid(_AlbumDrag data) =>
      _expanded &&
      _editable &&
      identical(data.base, org.snapshot) &&
      data.generation == browser.generation &&
      data.directoryRevision == org.directoryRevision;

  void _endDrag() {
    _edgeTicker.stop();
    _pointer = null;
    if (mounted) {
      setState(() {
        _drag = null;
        _hover.value = null;
      });
    }
  }

  void _scrollEdge(double seconds) {
    if (_pointer == null ||
        !_scroll.hasClients ||
        _drag == null ||
        !_valid(_drag!)) {
      return;
    }
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final point = box.globalToLocal(_pointer!);
    if (point.dx < 0 ||
        point.dx > box.size.width ||
        point.dy < 0 ||
        point.dy > box.size.height) {
      return;
    }
    final edgeExtent = math.min(44.0, box.size.height / 2);
    final delta = point.dy < edgeExtent
        ? -300.0 * seconds
        : point.dy > box.size.height - edgeExtent
        ? 300.0 * seconds
        : 0.0;
    final next = (_scroll.offset + delta).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    if (delta != 0 && next != _scroll.offset) {
      _hover.value = null;
      _scroll.jumpTo(next);
    }
  }

  Widget _draggable(_AlbumDrag data, String name, Widget child) {
    final row = ConstrainedBox(
      key: data.id == _createdRowId ? _createdRowKey : null,
      constraints: const BoxConstraints(minHeight: 48),
      child: child,
    );
    return LongPressDraggable<_AlbumDrag>(
      data: data,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      maxSimultaneousDrags: _editable && _drag == null ? 1 : 0,
      feedback: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        child: Padding(padding: const EdgeInsets.all(16), child: Text(name)),
      ),
      childWhenDragging: Opacity(opacity: .35, child: row),
      onDragStarted: () {
        setState(() => _drag = data);
        _lastEdgeTick = Duration.zero;
        _edgeTicker.start();
      },
      onDragUpdate: (details) => _pointer = details.globalPosition,
      onDragEnd: (details) {
        if (!details.wasAccepted &&
            _expanded &&
            !identical(data.base, org.snapshot)) {
          _stale();
        } else if (!details.wasAccepted &&
            _expanded &&
            (data.generation != browser.generation ||
                data.directoryRevision != org.directoryRevision)) {
          _stale();
        }
        _endDrag();
      },
      child: row,
    );
  }

  Future<void> _relocate(_AlbumDrag data, String target) async {
    if (!_valid(data)) {
      _stale();
      return;
    }
    await _report(
      data.folder
          ? org.moveFolder(
              data.id,
              target,
              base: data.base,
              expectedParent: data.parent,
              generation: data.generation,
              directoryRevision: data.directoryRevision,
            )
          : org.moveAlbum(
              data.id,
              target,
              generation: data.generation,
              base: data.base,
              expectedParent: data.parent,
              directoryRevision: data.directoryRevision,
            ),
    );
  }

  void _stale() {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.tr('相册或分类已变化，请重新操作'))));
  }

  Future<void> _reorder(_AlbumDrag data, int insertion) async {
    if (!_valid(data)) {
      _stale();
      return;
    }
    final folders = data.base.children(data.parent).map((f) => f.id).toList();
    final currentAlbums = data.base.albums(data.parent, org.albums);
    final albums = currentAlbums.map((a) => a.key).toList();
    final ids = data.folder
        ? folders
        : currentAlbums
              .where((a) => !org.isHiddenEmptyAlbum(a))
              .map((a) => a.key)
              .toList();
    final old = ids.indexOf(data.id);
    if (old < 0) {
      _stale();
      return;
    }
    final target = insertion > old ? insertion - 1 : insertion;
    if (old == target) return;
    ids.insert(target, ids.removeAt(old));
    if (!data.folder) {
      // Hidden albums keep their original slots; reorder only visible rows.
      final visible = ids.toSet();
      var at = 0;
      for (var i = 0; i < albums.length; i++) {
        if (visible.contains(albums[i])) albums[i] = ids[at++];
      }
    }
    await _report(
      org.saveOrder(
        parent: data.parent,
        base: data.base,
        generation: data.generation,
        directoryRevision: data.directoryRevision,
        folders: folders,
        albums: albums,
      ),
    );
  }

  bool _insideTarget(String name, Offset point) {
    final box =
        _targetKeys[name]?.currentContext?.findRenderObject() as RenderBox?;
    final viewport = _listKey.currentContext?.findRenderObject() as RenderBox?;
    return box != null &&
        box.attached &&
        box.hasSize &&
        viewport != null &&
        viewport.hasSize &&
        (box.localToGlobal(Offset.zero) & box.size).contains(point) &&
        (viewport.localToGlobal(Offset.zero) & viewport.size).contains(point);
  }

  bool _dropCurrent(String name, _AlbumDrag data, Offset point) {
    if (!_valid(data) || _hover.value != name || !_insideTarget(name, point)) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr('落点已变化，请重新拖动'))));
      }
      return false;
    }
    return true;
  }

  Widget _slot(String parent, bool folder, int index, {String suffix = ''}) {
    final name = 'insert-$parent-${folder ? 'folder' : 'album'}-$index$suffix';
    return SizedBox(
      key: _targetKeys.putIfAbsent(name, GlobalKey.new),
      child: DragTarget<_AlbumDrag>(
        key: ValueKey(name),
        onWillAcceptWithDetails: (d) {
          final ok =
              _valid(d.data) &&
              d.data.parent == parent &&
              d.data.folder == folder &&
              _insideTarget(name, d.offset);
          if (ok) _hover.value = name;
          return ok;
        },
        onLeave: (_) {
          if (_hover.value == name) _hover.value = null;
        },
        onMove: (d) {
          if (_valid(d.data) &&
              d.data.parent == parent &&
              d.data.folder == folder &&
              _insideTarget(name, d.offset)) {
            _hover.value = name;
          }
        },
        onAcceptWithDetails: (d) {
          if (_dropCurrent(name, d.data, d.offset)) _reorder(d.data, index);
        },
        builder: (_, candidates, _) => ValueListenableBuilder<String?>(
          valueListenable: _hover,
          builder: (context, hover, _) => SizedBox(
            height: 12,
            child: Center(
              child: Container(
                height: 3,
                color: _hover.value == name
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _destination(String id, Widget child) {
    final name = 'drop-$id';
    return ValueListenableBuilder<String?>(
      valueListenable: _hover,
      child: child,
      builder: (context, hover, row) => Material(
        borderRadius: BorderRadius.circular(12),
        color: hover == name
            ? Theme.of(context).colorScheme.primaryContainer
            : Colors.transparent,
        child: Stack(
          children: [
            row!,
            // The actual hit region must match acceptance geometry. Rejecting
            // an edge on entry cannot later activate the same DragTarget when
            // the pointer moves into its center.
            Positioned.fill(
              top: id == rootFolder ? 0 : 6,
              bottom: id == rootFolder ? 0 : 6,
              child: IgnorePointer(
                ignoring: _drag == null,
                child: SizedBox(
                  key: _targetKeys.putIfAbsent(name, GlobalKey.new),
                  child: DragTarget<_AlbumDrag>(
                    key: ValueKey(name),
                    onWillAcceptWithDetails: (d) {
                      final ok =
                          _valid(d.data) &&
                          (!d.data.folder ||
                              !org.snapshot.includes(d.data.id, id)) &&
                          d.data.parent != id &&
                          org.snapshot.exists(id) &&
                          _insideTarget(name, d.offset);
                      if (ok) _hover.value = name;
                      return ok;
                    },
                    onLeave: (_) {
                      if (_hover.value == name) _hover.value = null;
                    },
                    onMove: (d) {
                      final ok =
                          _valid(d.data) &&
                          (!d.data.folder ||
                              !org.snapshot.includes(d.data.id, id)) &&
                          d.data.parent != id &&
                          org.snapshot.exists(id) &&
                          _insideTarget(name, d.offset);
                      if (ok) {
                        _hover.value = name;
                      } else if (_hover.value == name) {
                        _hover.value = null;
                      }
                    },
                    onAcceptWithDetails: (d) {
                      if (_dropCurrent(name, d.data, d.offset)) {
                        _relocate(d.data, id);
                      }
                    },
                    builder: (_, candidates, rejected) =>
                        const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            if (hover == name)
              Positioned(
                right: 48,
                bottom: 0,
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Text(
                      id == rootFolder
                          ? context.tr('移到根目录')
                          : context.tr('移入此处'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _createAlbum(String parent) async {
    if (!_canEdit()) return;
    setState(() => _openFolders.addAll(org.snapshot.path(parent)));
    String? created;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PhysicalAlbumPage(
          organization: org,
          parent: parent,
          onCreated: (key) => created = key,
        ),
      ),
    );
    if (created != null && mounted) await _revealCreated(created!, parent);
  }

  Future<void> _deletePhysicalAlbum(Album album, String parent) async {
    final directory = physicalAlbumDirectory(album);
    final operations = widget.physical;
    if (directory == null || operations == null) {
      _stale();
      return;
    }
    final previous = operations.records.map((record) => record.id).toSet();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PhysicalOperationsPage(
          operations: operations,
          album: directory,
          directoryAccess: widget.directoryAccess,
        ),
      ),
    );
    if (!mounted || widget.selectedAlbumKey != album.key) return;
    final deletedHere = operations.records.any(
      (record) =>
          !previous.contains(record.id) &&
          record.album?.key == album.key &&
          record.directoryOutcome == PhysicalOutcome.confirmed &&
          record.directoryPrivateCommitted,
    );
    if (!deletedHere) return;
    // A missing/permission-hidden album is not deletion evidence. Only this
    // explicitly completed deletion leaves its selection and returns to parent.
    setState(() {
      _current = org.snapshot.exists(parent) ? parent : rootFolder;
      _lastPath = org.snapshot.path(_current);
      _openFolders.addAll(_lastPath);
    });
    widget.onAlbumSelected(null);
    _setExpanded(true);
  }

  Widget _menu({
    AlbumFolder? folder,
    Album? album,
    required int index,
    required int siblingCount,
  }) {
    final id = folder?.id ?? album!.key;
    final parent = folder?.parent ?? org.snapshot.parentOfAlbum(id);
    final data = _token(id, parent, folder != null);
    return PopupMenuButton<String>(
      tooltip: context.tr('管理 {0}', [
        folder?.name ?? context.albumName(album!),
      ]),
      icon: const Icon(Icons.more_vert, size: 20),
      enabled: _editable && _drag == null,
      onOpened: () => _menuSource = data,
      onCanceled: () => _menuSource = null,
      onSelected: (action) {
        final opened = _menuSource;
        _menuSource = null;
        if (!_canEdit()) return;
        if (opened == null || !_valid(opened)) {
          _stale();
          return;
        }
        switch (action) {
          case 'up':
            _reorder(data, index - 1);
          case 'down':
            _reorder(data, index + 2);
          case 'move':
            _move(folder: folder, album: album);
          case 'rename':
            _name(folder: folder);
          case 'dissolve':
            _dissolve(folder!);
          case 'delete':
            _delete(folder!);
          case 'newFolder':
            setState(() {
              _go(folder!.id);
              _openFolders.add(folder.id);
            });
            _name(inFolder: folder!.id);
          case 'newAlbum':
            setState(() {
              _go(folder!.id);
              _openFolders.add(folder.id);
            });
            _createAlbum(folder!.id);
          case 'physicalDelete':
            _deletePhysicalAlbum(album!, parent);
          case 'folderDetails':
            showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(folder!.name),
                scrollable: true,
                content: SelectableText(
                  org.snapshot.path(folder.id).map(_label).join(' / '),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(context.tr('关闭')),
                  ),
                ],
              ),
            );
          case 'details':
            showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(context.albumName(album!)),
                scrollable: true,
                content: SelectableText(album.directory),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(context.tr('关闭')),
                  ),
                ],
              ),
            );
          case 'hideEmpty':
            _report(org.hideEmptyAlbum(album!.key));
          case 'directory':
            Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => DirectoryAccessPage(
                  directory: DirectoryIdentity(
                    album!.key.substring(0, album.key.indexOf(':')),
                    album.directory,
                  ),
                  access: widget.directoryAccess!,
                ),
              ),
            );
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'up',
          enabled: index > 0,
          child: Text(context.tr('上移')),
        ),
        PopupMenuItem(
          value: 'down',
          enabled: index >= 0 && index + 1 < siblingCount,
          child: Text(context.tr('下移')),
        ),
        PopupMenuItem(value: 'move', child: Text(context.tr('移到文件夹'))),
        if (folder != null) ...[
          PopupMenuItem(
            value: 'folderDetails',
            child: Text(context.tr('文件夹路径')),
          ),
          PopupMenuItem(
            value: 'newFolder',
            child: Text(context.tr('在此新建相册文件夹')),
          ),
          if (org.physicalCreationAvailable)
            PopupMenuItem(value: 'newAlbum', child: Text(context.tr('在此新建相册'))),
          PopupMenuItem(value: 'rename', child: Text(context.tr('重命名'))),
          const PopupMenuDivider(),
          PopupMenuItem(value: 'dissolve', child: Text(context.tr('解散文件夹'))),
          PopupMenuItem(
            value: 'delete',
            child: Text(
              context.tr('删除空文件夹'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ] else ...[
          PopupMenuItem(value: 'details', child: Text(context.tr('相册详情'))),
          if (widget.directoryAccess != null)
            PopupMenuItem(
              value: 'directory',
              child: Text(context.tr('目录权限与能力')),
            ),
          if (org.canHideEmptyAlbum(album!))
            PopupMenuItem(value: 'hideEmpty', child: Text(context.tr('隐藏空相册'))),
          if (widget.physical != null &&
              physicalAlbumDirectory(album) != null) ...[
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'physicalDelete',
              child: Text(
                context.tr('删除真实相册'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _sortableBranch(
    String parent,
    bool folder,
    int index,
    int count,
    Widget content,
  ) => Stack(
    children: [
      content,
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        height: 6,
        child: IgnorePointer(
          ignoring:
              _drag == null ||
              _drag!.parent != parent ||
              _drag!.folder != folder,
          child: _slot(parent, folder, index),
        ),
      ),
      Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        height: 6,
        child: IgnorePointer(
          ignoring:
              _drag == null ||
              _drag!.parent != parent ||
              _drag!.folder != folder,
          child: _slot(
            parent,
            folder,
            index + 1,
            suffix: index + 1 == count ? '' : '-after',
          ),
        ),
      ),
    ],
  );

  List<Widget> _tree(String parent, int depth, List<Album> visibleAlbums) {
    final folders = org.snapshot.children(parent);
    final albums = org.snapshot
        .albums(parent, visibleAlbums)
        .where((a) => !org.isHiddenEmptyAlbum(a))
        .toList();
    final indent = (depth * 14).clamp(0, 56).toDouble();
    Widget padded(Widget child) => Padding(
      padding: EdgeInsets.only(left: indent),
      child: child,
    );
    return [
      for (var i = 0; i < folders.length; i++)
        _sortableBranch(
          parent,
          true,
          i,
          folders.length,
          Column(
            children: [
              padded(
                _draggable(
                  _token(folders[i].id, parent, true),
                  folders[i].name,
                  _destination(
                    folders[i].id,
                    AlbumTreeRow(
                      key: ValueKey('folder-${folders[i].id}'),
                      titleGap: 4,
                      leading: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _openFolders.contains(folders[i].id)
                                ? Icons.keyboard_arrow_down
                                : Icons.keyboard_arrow_right,
                            size: 16,
                          ),
                          Icon(Icons.folder_outlined, size: 24),
                        ],
                      ),
                      title: folders[i].name,
                      onTap: () => setState(() {
                        _go(folders[i].id);
                        if (!_openFolders.add(folders[i].id)) {
                          _openFolders.remove(folders[i].id);
                        }
                      }),
                      trailing: _menu(
                        folder: folders[i],
                        index: i,
                        siblingCount: folders.length,
                      ),
                    ),
                  ),
                ),
              ),
              if (_openFolders.contains(folders[i].id))
                ..._tree(folders[i].id, depth + 1, visibleAlbums),
            ],
          ),
        ),
      for (var i = 0; i < albums.length; i++)
        _sortableBranch(
          parent,
          false,
          i,
          albums.length,
          padded(
            _draggable(
              _token(albums[i].key, parent, false),
              context.albumName(albums[i]),
              AlbumTreeRow(
                key: ValueKey(albums[i].key),
                selected: widget.selectedAlbumKey == albums[i].key,
                leading: SizedBox(
                  width: 32,
                  height: 32,
                  child: albums[i].photos.isEmpty
                      ? Icon(Icons.photo_album_outlined)
                      : PhotoTile(
                          key: ValueKey(
                            '${browser.imageGeneration}:${albums[i].photos.first.key}',
                          ),
                          browser: browser,
                          photo: albums[i].photos.first,
                          size: 32,
                        ),
                ),
                title: context.albumName(albums[i]),
                onTap: () => _openAlbum(albums[i]),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (albums[i].photos.isNotEmpty ||
                        albums[i].availability == AlbumAvailability.empty)
                      Text(
                        '${albums[i].photos.length}',
                        style: TextStyle(fontSize: 12),
                      ),
                    _menu(
                      album: albums[i],
                      index: i,
                      siblingCount: albums.length,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      if (parent == _current &&
          org.snapshot.invisibleCount(parent, visibleAlbums) > 0)
        padded(
          Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              context.tr('{0} 个暂不可见的归类关系；私有分类保留', [
                org.snapshot.invisibleCount(parent, visibleAlbums),
              ]),
            ),
          ),
        ),
      if (folders.isEmpty && albums.isEmpty)
        padded(
          Padding(
            padding: EdgeInsets.all(12),
            child: Text(context.tr('此处暂无可访问相册')),
          ),
        ),
    ];
  }

  // Use the primary foreground across the full user-controlled opacity range.
  Color get _sidebarSecondary => Theme.of(context).colorScheme.onSurface;

  ThemeData _sidebarTheme() {
    final theme = Theme.of(context);
    final text = theme.colorScheme.onSurface;
    return theme.copyWith(
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      colorScheme: theme.colorScheme.copyWith(
        onSurfaceVariant: _sidebarSecondary,
      ),
      textTheme: theme.textTheme.copyWith(
        bodySmall: theme.textTheme.bodySmall?.copyWith(
          color: _sidebarSecondary,
        ),
        labelLarge: theme.textTheme.labelLarge?.copyWith(
          color: _sidebarSecondary,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: text,
          minimumSize: const Size(48, 48),
        ),
      ),
      sliderTheme: theme.sliderTheme.copyWith(
        inactiveTrackColor: _sidebarSecondary,
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: EdgeInsets.fromLTRB(12, 10, 12, 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 14,
        height: 19 / 14,
        fontWeight: FontWeight.w600,
        color: _sidebarSecondary,
      ),
    ),
  );

  Widget _shortcut(LibraryView view, String title, IconData icon) {
    final selected =
        widget.selectedAlbumKey == null && widget.selectedView == view;
    final known =
        browser.phase == BrowsePhase.ready &&
        (view != LibraryView.images ||
            browser.permissions.images != PhotoAccess.denied) &&
        (view != LibraryView.videos ||
            browser.permissions.videos != PhotoAccess.denied) &&
        (view != LibraryView.favorite ||
            widget.favorites?.phase == FavoritePhase.ready);
    final count = known
        ? viewPhotos(
            browser.photos,
            view,
            widget.favorites,
            DateTime.now(),
          ).length
        : null;
    return AlbumTreeRow(
      key: ValueKey('scope-${view.name}'),
      selected: selected,
      leading: Icon(icon, size: 24),
      title: title,
      trailing: Padding(
        padding: EdgeInsets.only(right: 12),
        child: Text(
          count == null ? '—' : '$count',
          style: TextStyle(fontSize: 12),
        ),
      ),
      onTap: () {
        widget.onViewSelected(view);
        _setExpanded(false);
      },
    );
  }

  void _openAppearance() {
    _appearanceExpanded = true;
    _setExpanded(true);
  }

  Widget _appearanceSettings() => ValueListenableBuilder<int?>(
    valueListenable: widget.opacity,
    builder: (context, opacity, _) {
      final value =
          opacity ??
          (Theme.of(context).brightness == Brightness.dark ? 90 : 86);
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.tr('不透明度 {0}%', [value]),
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            Slider(
              key: ValueKey('sidebar-opacity'),
              value: value.toDouble(),
              min: 70,
              max: 100,
              divisions: 30,
              label: '$value%',
              onChanged: (value) => widget.onOpacityChanged(value.round()),
              onChangeEnd: (_) => widget.onOpacityChangeEnd(),
            ),
            if (MediaQuery.disableAnimationsOf(context))
              Text(
                context.tr('减少效果已开启：当前不透明且无模糊；保留所选设置'),
                style: TextStyle(fontSize: 12),
              ),
            ValueListenableBuilder<({String? message, bool canRetry})>(
              valueListenable: widget.opacityStatus,
              builder: (context, status, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (status.message != null)
                    Text(
                      context.domainText(status.message!),
                      style: TextStyle(fontSize: 12),
                    ),
                  if (status.canRetry)
                    TextButton(
                      onPressed: widget.retryOpacity,
                      child: Text(context.tr('重试设置')),
                    ),
                ],
              ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  onPressed: widget.onOpacityReset,
                  child: Text(context.tr('恢复默认')),
                ),
                TextButton(
                  onPressed: () => setState(() => _appearanceExpanded = false),
                  child: Text(context.tr('收起设置')),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );

  // A build-local projection: rows share it, while actions still revalidate
  // their captured token against the current organization and media state.
  Widget _management(List<Album> visibleAlbums) => LayoutBuilder(
    builder: (context, constraints) => Column(
      children: [
        Expanded(
          child: Material(
            key: _listKey,
            // Selection ink must be painted inside the same clip as the tree.
            type: MaterialType.transparency,
            clipBehavior: Clip.hardEdge,
            child: ListView(
              key: ValueKey('album-management-list'),
              controller: _scroll,
              children: [
                _sectionLabel(context.tr('照片库')),
                _shortcut(
                  LibraryView.all,
                  context.tr('所有媒体'),
                  Icons.photo_library_outlined,
                ),
                _shortcut(
                  LibraryView.favorite,
                  context.tr('收藏'),
                  Icons.favorite_border,
                ),
                _shortcut(LibraryView.recent, context.tr('最近'), Icons.schedule),
                if (browser.phase != BrowsePhase.ready)
                  Text(
                    browser.phase == BrowsePhase.denied
                        ? context.tr('媒体权限已拒绝 · 媒体数量不可确定')
                        : browser.phase == BrowsePhase.failed
                        ? context.tr('媒体查询失败 · 媒体数量不可确定')
                        : context.tr('正在核对媒体 · 媒体数量不可确定'),
                  ),
                if (browser.phase == BrowsePhase.denied ||
                    browser.phase == BrowsePhase.failed)
                  TextButton(
                    onPressed: () => browser.refresh(
                      request: browser.phase == BrowsePhase.denied,
                    ),
                    child: Text(
                      browser.phase == BrowsePhase.denied
                          ? context.tr('授予访问')
                          : context.tr('刷新重试'),
                    ),
                  ),
                if (org.busy) LinearProgressIndicator(),
                if (org.discoveryError != null)
                  ListTile(
                    title: Text(context.domainText(org.discoveryError!)),
                    trailing: TextButton(
                      onPressed: org.busy ? null : org.retryDiscovery,
                      child: Text(context.tr('重试保存')),
                    ),
                  ),

                _destination(
                  rootFolder,
                  ListTile(
                    key: ValueKey('album-section-heading'),
                    title: Text(
                      context.tr('相册'),
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    trailing: Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: IconButton(
                        key: ValueKey('album-create-plus'),
                        tooltip: context.tr('新建相册或相册文件夹'),
                        constraints: BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        icon: Icon(Icons.add, size: 24),
                        onPressed: _editable ? _createMenu : null,
                      ),
                    ),
                    onTap: () => _go(rootFolder),
                  ),
                ),
                ..._tree(rootFolder, 0, visibleAlbums),
                if (org.physicalCreationAvailable) ...[
                  if (org.creations.any((r) => r.unresolved))
                    TextButton(
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => CreationReviewPage(organization: org),
                        ),
                      ),
                      child: Text(context.tr('处理未完成的相册创建')),
                    ),
                  TextButton(
                    onPressed: org.busy ? null : org.refreshDirectories,
                    child: Text(context.tr('重新核对空相册')),
                  ),
                ],
                _sectionLabel(context.tr('媒体类型')),
                _shortcut(
                  LibraryView.images,
                  context.tr('图片'),
                  Icons.image_outlined,
                ),
                _shortcut(
                  LibraryView.videos,
                  context.tr('视频'),
                  Icons.video_library_outlined,
                ),
              ],
            ),
          ),
        ),

        Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.tr('新建位置：{0}', [
                    org.snapshot.path(_current).map(_label).join(' / '),
                  ]),
                  style: TextStyle(fontSize: 12),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Tooltip(
                message: context.tr('新建'),
                child: TextButton(
                  onPressed: _editable ? _createMenu : null,
                  child: Text(context.tr('新建')),
                ),
              ),
            ],
          ),
        ),
        if (_appearanceExpanded)
          ConstrainedBox(
            // Settings use their natural height until this cap, then scroll.
            // The tree alone expands into all remaining sidebar height.
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * .45),
            child: SingleChildScrollView(child: _appearanceSettings()),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ready = org.phase == OrganizationPhase.ready;
    return PopScope<void>(
      canPop: !_expanded,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _expanded) _setExpanded(false);
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The ordinary grid bar sits 8 dp from the top and is 56 dp tall.
          // In short windows leave room for the tree, its header and footer.
          final inset = math.min(
            64.0,
            math.max(0.0, (constraints.maxHeight - 440) / 2),
          );
          return Stack(
            children: [
              Positioned.fill(
                child: widget.contentBuilder(
                  context,
                  () => _setExpanded(!_expanded),
                  _openAppearance,
                  _expanded || !_panelMotion.isDismissed,
                ),
              ),
              if (_expanded || !_panelMotion.isDismissed)
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _panelMotion,
                    // Keep intercepting touches during the reverse transition;
                    // the still-visible overlay must not open a photo beneath it.
                    builder: (context, child) => Opacity(
                      opacity: Curves.easeOutCubic.transform(
                        _panelMotion.value,
                      ),
                      child: child,
                    ),
                    child: GestureDetector(
                      key: const ValueKey('album-panel-scrim'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _setExpanded(false),
                      child: const ColoredBox(color: Color(0x1F000000)),
                    ),
                  ),
                ),
              if (_expanded || !_panelMotion.isDismissed)
                Positioned(
                  left: 0,
                  top: inset,
                  bottom: inset,
                  width: math.min(320, constraints.maxWidth * .74),
                  child: AnimatedBuilder(
                    animation: _panelMotion,
                    builder: (context, child) => FractionalTranslation(
                      translation: Offset(
                        Curves.easeOutCubic.transform(_panelMotion.value) - 1,
                        0,
                      ),
                      child: IgnorePointer(ignoring: !_expanded, child: child),
                    ),
                    child: GestureDetector(
                      onHorizontalDragStart: (_) => _closeDistance = 0,
                      onHorizontalDragUpdate: (d) {
                        if (_drag == null) {
                          _closeDistance += d.primaryDelta ?? 0;
                        }
                      },
                      onHorizontalDragEnd: (d) {
                        if (_drag == null &&
                            (_closeDistance < -48 ||
                                (d.primaryVelocity ?? 0) < -450)) {
                          _setExpanded(false);
                        }
                      },
                      child: ValueListenableBuilder<int?>(
                        valueListenable: widget.opacity,
                        builder: (context, opacity, child) => GlassSurface(
                          key: const ValueKey('album-management-panel'),
                          opacity:
                              (opacity ??
                                  (Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? 90
                                      : 86)) /
                              100,
                          borderRadius: PhotoTreeStyle.panelRadius,
                          child: child!,
                        ),
                        child: Material(
                          type: MaterialType.transparency,
                          child: Theme(
                            data: _sidebarTheme(),
                            child: ListTileTheme(
                              data: ListTileThemeData(
                                visualDensity: VisualDensity.standard,
                                minTileHeight: 48,
                                selectedTileColor: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer,
                                minLeadingWidth: 24,
                                horizontalTitleGap: 12,
                                contentPadding: const EdgeInsets.only(
                                  left: 12,
                                  right: 0,
                                ),
                                titleTextStyle: Theme.of(context)
                                    .textTheme
                                    .bodyMedium!
                                    .copyWith(
                                      fontSize: 16,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface,
                                    ),
                                subtitleTextStyle: Theme.of(context)
                                    .textTheme
                                    .bodySmall!
                                    .copyWith(
                                      fontSize: 12,
                                      color: _sidebarSecondary,
                                    ),
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Text(
                                          context.tr('相册管理'),
                                          style: TextStyle(
                                            fontSize: 19,
                                            height: 26 / 19,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: context.tr('整理说明'),
                                        icon: Icon(
                                          Icons.help_outline,
                                          size: 20,
                                        ),
                                        onPressed: () => showDialog<void>(
                                          context: context,
                                          builder: (_) =>
                                              const _OrganizationHelpDialog(),
                                        ),
                                      ),
                                      IconButton(
                                        key: const ValueKey('sidebar-close'),
                                        tooltip: context.tr('收起相册管理'),
                                        onPressed: () => _setExpanded(false),
                                        icon: Icon(Icons.chevron_left),
                                      ),
                                    ],
                                  ),
                                  Expanded(
                                    child: ready
                                        ? _management(org.albums)
                                        : Center(
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  org.phase ==
                                                          OrganizationPhase
                                                              .loading
                                                      ? context.tr('正在加载相册分类…')
                                                      : context.tr(
                                                          '相册分类暂时无法加载，原有分类已保留',
                                                        ),
                                                ),
                                                TextButton(
                                                  onPressed:
                                                      org.phase ==
                                                          OrganizationPhase
                                                              .loading
                                                      ? null
                                                      : org.load,
                                                  child: Text(
                                                    context.tr('重试加载'),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _OrganizationHelpDialog extends StatelessWidget {
  const _OrganizationHelpDialog();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget step(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 20, color: colors.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 15,
                height: 22 / 15,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
    return Dialog(
      constraints: const BoxConstraints(maxWidth: 340),
      insetPadding: const EdgeInsets.all(24),
      elevation: 4,
      shadowColor: const Color(0x1A000000),
      shape: RoundedRectangleBorder(
        borderRadius: PhotoTreeStyle.panelRadius,
        side: BorderSide(color: colors.onSurface.withValues(alpha: .10)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: colors.primaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.folder_outlined,
                            size: 20,
                            color: colors.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            context.tr('整理相册'),
                            style: TextStyle(
                              fontSize: 17,
                              height: 24 / 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    step(Icons.open_with_rounded, context.tr('长按并拖动，调整顺序')),
                    step(
                      Icons.drive_file_move_outline,
                      context.tr('拖入文件夹，归类相册'),
                    ),
                    step(Icons.done_rounded, context.tr('松手后自动保存')),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors.onSurface.withValues(alpha: .04),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        context.tr('仅调整应用内分类，不移动照片文件。'),
                        style: TextStyle(
                          fontSize: 12,
                          height: 18 / 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.tonal(
                onPressed: () => Navigator.pop(context),
                child: Text(context.tr('知道了')),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlbumDrag {
  const _AlbumDrag(
    this.id,
    this.parent,
    this.folder,
    this.base,
    this.generation,
    this.directoryRevision,
  );
  final String id, parent;
  final bool folder;
  final OrganizationSnapshot base;
  final int generation, directoryRevision;
}

class _FolderNameDialog extends StatefulWidget {
  const _FolderNameDialog({
    required this.initial,
    required this.title,
    required this.path,
    required this.save,
  });
  final String initial, title, path;
  final Future<String?> Function(String) save;
  @override
  State<_FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<_FolderNameDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.save(_controller.text);
    // A popped dialog remains mounted during its exit animation. A completed
    // write must not pop the page underneath it during that interval.
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // A tall landscape keyboard can leave less room than the fixed actions.
    // Let the entire form scroll in that case, including its unchanged actions.
    final compact =
        media.size.height - media.viewInsets.bottom - media.padding.vertical <
        200;
    final actions = [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.tr('取消')),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: Text(_busy ? context.tr('保存中…') : context.tr('保存')),
      ),
    ];
    return AlertDialog(
      title: Text(widget.title, textAlign: TextAlign.center),
      scrollable: true,
      insetPadding: compact
          ? const EdgeInsets.symmetric(horizontal: 24, vertical: 4)
          : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.path, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            // Keep pasted newlines intact so the domain rejects them explicitly;
            // a single-line TextField would silently strip them before validation.
            minLines: 1,
            maxLines: 2,
            textInputAction: TextInputAction.done,
            autofocus: true,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: context.tr('文件夹名称'),
              helperText: context.tr('1–64 个字符，仅应用内使用'),
              errorText: _error == null ? null : context.domainText(_error!),
              errorMaxLines: 3,
            ),
            onSubmitted: (_) => _save(),
          ),
          if (compact) ...[
            const SizedBox(height: 16),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              children: actions,
            ),
          ],
        ],
      ),
      actions: compact ? null : actions,
    );
  }
}

// A display label only: directory identity remains owned by the media layer.
String albumDirectoryLabel(Album album, Iterable<Album> peers) {
  final duplicates = peers.where((a) => a.name == album.name).toList();
  if (duplicates.length < 2) return '';
  final parts = album.directory.split('/').where((p) => p.isNotEmpty).toList();
  for (var count = 1; count <= parts.length; count++) {
    final suffix = parts.skip(parts.length - count).join('/');
    if (duplicates
            .where(
              (a) =>
                  a.directory.replaceAll(RegExp(r'/+$'), '').endsWith(suffix),
            )
            .length ==
        1) {
      return '$suffix · ';
    }
  }
  return '${album.directory} · ';
}

class _CreationMenu extends StatelessWidget {
  const _CreationMenu({
    required this.path,
    required this.missing,
    required this.canCreateAlbum,
  });
  final String path;
  final bool missing, canCreateAlbum;

  @override
  Widget build(BuildContext context) {
    Widget choice(
      String value,
      IconData icon,
      String title,
      String subtitle,
    ) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.pop(context, value),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(icon, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right, size: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(16),
      constraints: const BoxConstraints(maxWidth: 360),
      child: GlassSurface(
        key: const ValueKey('creation-menu'),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        context.tr('新建'),
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (missing) Text(context.tr('原位置已失效，已改为根目录')),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.tr('创建位置'),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                                Text(
                                  path,
                                  key: const ValueKey('creation-location-path'),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            style: TextButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: () => Navigator.pop(context, 'location'),
                            child: Text(context.tr('更改位置')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      choice(
                        'folder',
                        Icons.create_new_folder_outlined,
                        context.tr('相册文件夹'),
                        context.tr('应用内分类'),
                      ),
                      if (canCreateAlbum)
                        choice(
                          'album',
                          Icons.photo_album_outlined,
                          context.tr('相册'),
                          context.tr('真实目录'),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => Navigator.pop(context),
                child: Text(context.tr('取消')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

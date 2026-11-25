import 'interface_strings.dart';
import 'language_setting.dart';
import '../library/physical_operations.dart';
import 'physical_operations_page.dart';
import '../storage/directory_access.dart';
import '../backup/backup_restore.dart';
import 'restore_page.dart';
import '../backup/backup_export.dart';
import 'backup_home_page.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../organization/organization.dart';
import 'album_folders.dart';
import 'favorite_migration_page.dart';
import 'physical_album_page.dart';

import '../dev/motion_probe.dart';
import '../media/browser.dart';
import 'photo_grid.dart';
import '../library/favorites.dart';
import '../library/views.dart';
import '../media/media_source.dart';
import 'visual_style.dart';

class LibraryShell extends StatefulWidget {
  const LibraryShell({
    super.key,
    required this.browser,
    this.favorites,
    this.physical,
    this.directoryAccess,
    this.backup,
    this.restore,
    required this.organization,
    this.readSidebarOpacity,
    this.saveSidebarOpacity,
  });
  final Future<int?> Function()? readSidebarOpacity;
  final Future<void> Function(int?)? saveSidebarOpacity;
  final Favorites? favorites;
  final PhysicalOperations? physical;
  final DirectoryAccess? directoryAccess;
  final BackupExport? backup;
  final BackupRestore? restore;
  final Organization organization;
  final PhotoBrowser browser;

  @override
  State<LibraryShell> createState() => _LibraryShellState();
}

class _LibraryShellState extends State<LibraryShell> {
  @override
  void initState() {
    super.initState();
    widget.restore?.addListener(_restoreChanged);
    widget.organization.addListener(_restoreChanged);
    widget.browser.addListener(_restoreChanged);
    _loadSidebarOpacity();
    _updateOpacityFeedback();
  }

  void _restoreChanged() {
    if (mounted) {
      setState(() {
        if (_scope.albumKey != null) {
          final selected = widget.organization.albums
              .where((a) => a.key == _scope.albumKey)
              .firstOrNull;
          if (selected != null &&
              widget.organization.isHiddenEmptyAlbum(selected)) {
            _scope = (view: LibraryView.all, albumKey: null);
          }
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant LibraryShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.browser != widget.browser) {
      oldWidget.browser.removeListener(_restoreChanged);
      widget.browser.addListener(_restoreChanged);
    }
    if (oldWidget.organization != widget.organization) {
      oldWidget.organization.removeListener(_restoreChanged);
      widget.organization.addListener(_restoreChanged);
    }
    if (oldWidget.restore != widget.restore) {
      oldWidget.restore?.removeListener(_restoreChanged);
      widget.restore?.addListener(_restoreChanged);
    }
  }

  @override
  void dispose() {
    widget.restore?.removeListener(_restoreChanged);
    widget.organization.removeListener(_restoreChanged);
    widget.browser.removeListener(_restoreChanged);
    _sidebarOpacity.dispose();
    _opacityFeedback.dispose();
    super.dispose();
  }

  final _sidebarOpacity = ValueNotifier<int?>(null);
  final _opacityFeedback = ValueNotifier<({String? message, bool canRetry})>((
    message: null,
    canRetry: false,
  ));
  int _opacityRevision = 0;
  bool _opacityReadingFailed = false, _opacitySavingFailed = false;
  bool _opacitySaving = false;
  ({int? value, int revision})? _pendingOpacity;

  Future<void> _loadSidebarOpacity() async {
    final read = widget.readSidebarOpacity;
    if (read == null) return;
    final revision = _opacityRevision;
    try {
      final value = await read();
      if (!mounted || revision != _opacityRevision) return;
      if (value != null && (value < 40 || value > 100)) {
        throw const FormatException('Invalid sidebar opacity');
      }
      _sidebarOpacity.value = value?.clamp(70, 100);
      _opacityReadingFailed = false;
      _updateOpacityFeedback();
      if (value != null && value < 70) {
        // Migrate through the same serialized writer as a deliberate choice.
        // The revision check above prevents a late read replacing user input.
        await _saveSidebarOpacity();
      }
    } catch (_) {
      if (mounted && revision == _opacityRevision) {
        _opacityReadingFailed = true;
        _updateOpacityFeedback();
      }
    }
  }

  void _previewSidebarOpacity(int value) {
    _opacityRevision++;
    _sidebarOpacity.value = value.clamp(70, 100);
  }

  void _resetSidebarOpacity() {
    _opacityRevision++;
    _sidebarOpacity.value = null;
    _saveSidebarOpacity();
  }

  Future<void> _saveSidebarOpacity() async {
    final save = widget.saveSidebarOpacity;
    if (save == null) return;
    _pendingOpacity = (
      value: _sidebarOpacity.value,
      revision: _opacityRevision,
    );
    if (_opacitySaving) return;
    _opacitySaving = true;
    _updateOpacityFeedback();
    // A completed slider gesture queues one preference write. If another ends
    // during that write, save its latest value next, even if the UI is disposed.
    while (_pendingOpacity != null) {
      final pending = _pendingOpacity!;
      _pendingOpacity = null;
      try {
        await save(pending.value);
        if (mounted && pending.revision == _opacityRevision) {
          _opacitySavingFailed = false;
          _opacityReadingFailed = false;
          _updateOpacityFeedback();
        }
      } catch (_) {
        if (mounted && pending.revision == _opacityRevision) {
          _opacitySavingFailed = true;
          _updateOpacityFeedback();
        }
      }
    }
    _opacitySaving = false;
    _updateOpacityFeedback();
  }

  void _updateOpacityFeedback() {
    if (!mounted) return;
    _opacityFeedback.value = (
      message: _opacityStatus,
      canRetry:
          !_opacitySaving && (_opacitySavingFailed || _opacityReadingFailed),
    );
  }

  void _retryOpacity() {
    if (_opacitySavingFailed) {
      _saveSidebarOpacity();
    } else if (_opacityReadingFailed) {
      _loadSidebarOpacity();
    }
  }

  String? get _opacityStatus => _opacitySaving
      ? '正在保存设置'
      : _opacitySavingFailed
      ? '保存失败，仅本次生效'
      : _opacityReadingFailed
      ? '读取设置失败，当前使用默认值'
      : widget.saveSidebarOpacity == null
      ? '仅本次生效'
      : null;

  ({LibraryView view, String? albumKey}) _scope = (
    view: LibraryView.all,
    albumKey: null,
  );
  GridDensity _density = GridDensity.compact;
  bool _menuOpen = false;
  final _positions = <String, GridPosition>{};

  void _selectView(LibraryView view) => setState(() {
    _scope = (view: view, albumKey: null);
  });

  void _selectAlbum(String? key) => setState(() {
    _scope = (view: LibraryView.all, albumKey: key);
  });

  void _openRecords() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PhysicalOperationsPage(operations: widget.physical!),
      ),
    );
  }

  Widget _moreButton(VoidCallback openAppearance) => PopupMenuButton<String>(
    tooltip: context.tr('更多'),
    icon: const Icon(Icons.more_horiz),
    constraints: BoxConstraints.tightFor(
      width: (MediaQuery.sizeOf(context).width - 32).clamp(0, 232),
    ),
    onOpened: () => setState(() => _menuOpen = true),
    onCanceled: () => setState(() => _menuOpen = false),
    onSelected: (value) {
      setState(() => _menuOpen = false);
      final density = GridDensity.values
          .where((d) => d.name == value)
          .firstOrNull;
      if (density != null) {
        setState(() => _density = density);
      } else if (value == 'appearance') {
        openAppearance();
      } else if (value == 'refresh') {
        widget.browser.refresh(
          request: widget.browser.phase == BrowsePhase.denied,
        );
      } else if (value == 'records') {
        _openRecords();
      } else if (value == 'more') {
        Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (context) => Scaffold(
              appBar: photoTreePageBar(context, title: context.tr('更多')),
              body: _buildBrowse(context),
            ),
          ),
        );
      }
    },
    itemBuilder: (_) => [
      _DensityMenuEntry(density: _density),
      const PopupMenuDivider(),
      _menuAction(
        'appearance',
        context.tr('侧栏外观'),
        Icons.view_sidebar_outlined,
      ),
      _menuAction('refresh', context.tr('刷新'), Icons.refresh_rounded),
      if (widget.physical != null)
        _menuAction('records', context.tr('操作记录'), Icons.history_rounded),
      _menuAction('more', context.tr('更多功能'), Icons.more_horiz),
    ],
  );

  PopupMenuItem<String> _menuAction(
    String value,
    String label,
    IconData icon,
  ) => PopupMenuItem(
    value: value,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                height: 21 / 15,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget? _albumEmptyContent(Album? album) {
    if (_scope.albumKey == null) return null;
    final message = album == null
        ? '所选相册暂不可访问，未切换到其他同名相册'
        : album.availability == AlbumAvailability.empty
        ? '已核对真实空目录 · 0 项'
        : album.availability != AlbumAvailability.indexed
        ? (album.status == null ? null : context.domainText(album.status!)) ??
              '目录状态待核对'
        : null;
    if (message == null) return null;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.photo_library_outlined, size: 48),
          const SizedBox(height: 16),
          Text(context.domainText(message), textAlign: TextAlign.center),
          TextButton(
            onPressed: () {
              widget.organization.refreshDirectories();
              widget.browser.refresh();
            },
            child: Text(context.tr('重试 / 刷新')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.organization.albums
        .where((a) => a.key == _scope.albumKey)
        .firstOrNull;
    final title = _scope.albumKey != null
        ? album == null
              ? context.tr('所选相册暂不可用')
              : context.albumName(album)
        : switch (_scope.view) {
            LibraryView.all => context.tr('所有媒体'),
            LibraryView.favorite => context.tr('收藏'),
            LibraryView.recent => context.tr('最近'),
            LibraryView.images => context.tr('图片'),
            LibraryView.videos => context.tr('视频'),
          };
    final scopeKey = _scope.albumKey == null
        ? 'view:${_scope.view.name}'
        : 'album:${_scope.albumKey}';
    return Scaffold(
      // Dialogs own keyboard insets; the underlying grid and sidebar stay put.
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Column(
          children: [
            CreationBlockNotice(organization: widget.organization),
            if (widget.organization.phase != OrganizationPhase.ready)
              MaterialBanner(
                content: Text(
                  widget.organization.phase == OrganizationPhase.loading
                      ? context.tr('正在加载组织数据，媒体浏览仍可使用')
                      : context.tr('组织数据加载失败，原有分类未清除'),
                ),
                actions: [
                  TextButton(
                    onPressed:
                        widget.organization.phase == OrganizationPhase.loading
                        ? null
                        : widget.organization.load,
                    child: Text(context.tr('重试加载')),
                  ),
                ],
              ),
            if (widget.physical != null)
              AnimatedBuilder(
                animation: widget.physical!,
                builder: (context, _) =>
                    widget.physical!.busy || widget.physical!.blocked
                    ? ListTile(
                        dense: true,
                        leading: const Icon(Icons.info_outline),
                        title: Text(
                          widget.physical!.busy
                              ? context.tr('正在处理真实操作')
                              : context.tr('真实操作待核对'),
                        ),
                        trailing: TextButton(
                          onPressed: _openRecords,
                          child: Text(context.tr('操作记录')),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            if (widget.restore?.blocked == true)
              MaterialBanner(
                content: Text(context.tr('私有数据恢复未完成，分类、收藏编辑和导出已暂停。媒体浏览仍可使用。')),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => RestorePage(restore: widget.restore!),
                      ),
                    ),
                    child: Text(context.tr('查看并重试恢复')),
                  ),
                ],
              ),
            Expanded(
              child: AlbumFoldersPage(
                organization: widget.organization,
                browser: widget.browser,
                physical: widget.physical,
                directoryAccess: widget.directoryAccess,
                favorites: widget.favorites,
                selectedAlbumKey: _scope.albumKey,
                selectedView: _scope.view,
                onAlbumSelected: _selectAlbum,
                onViewSelected: _selectView,
                opacity: _sidebarOpacity,
                onOpacityChanged: _previewSidebarOpacity,
                onOpacityChangeEnd: _saveSidebarOpacity,
                onOpacityReset: _resetSidebarOpacity,
                opacityStatus: _opacityFeedback,
                retryOpacity: _retryOpacity,
                contentBuilder:
                    (context, toggle, openAppearance, panelVisible) =>
                        PhotoGrid(
                          key: ValueKey(scopeKey),
                          browser: widget.browser,
                          favorites: widget.favorites,
                          physical: widget.physical,
                          albumKey: _scope.albumKey,
                          view: _scope.view,
                          position: _positions.putIfAbsent(
                            scopeKey,
                            GridPosition.new,
                          ),
                          density: _density,
                          onDensityChanged: (value) =>
                              setState(() => _density = value),
                          scopeTitle: title,
                          emptyContent: _albumEmptyContent(album),
                          glassEnabled: !panelVisible && !_menuOpen,
                          navigationButton: IconButton(
                            key: const ValueKey('album-panel-toggle'),
                            tooltip: context.tr('相册侧栏'),
                            onPressed: toggle,
                            icon: const Icon(Icons.menu),
                          ),
                          menuButton: _moreButton(openAppearance),
                        ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrowse(BuildContext context) {
    return ListView(
      key: const PageStorageKey('browse'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        _BrowseSection(
          title: context.tr('通用'),
          children: const [LanguageSetting()],
        ),
        if (widget.physical != null)
          _BrowseSection(
            title: context.tr('真实操作'),
            children: [
              _BrowseEntry(
                title: context.tr('操作记录'),
                icon: Icons.receipt_long_outlined,
                onTap: _openRecords,
              ),
            ],
          ),
        if (widget.favorites case final favorites?)
          _BrowseSection(
            title: context.tr('收藏设置'),
            children: [
              ListenableBuilder(
                listenable: Listenable.merge([
                  favorites,
                  favorites.browser,
                  favorites.guard,
                ]),
                builder: (context, _) => SwitchListTile(
                  title: Text(context.tr('与系统相册互通图片收藏')),
                  value: favorites.systemMode,
                  subtitle: Text(
                    !favorites.syncAvailable
                        ? context.tr('此设备无法使用系统收藏')
                        : favorites.browser.permissions.images ==
                              PhotoAccess.denied
                        ? context.tr('请先在图库授予图片访问权限')
                        : favorites.syncFailed
                        ? context.tr('未能核对收藏，请刷新后重试')
                        : context.tr('手机相册使用系统收藏标记时，两边的更改会同步'),
                  ),
                  onChanged: favorites.canSwitch
                      ? (value) async {
                          if (value) {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (dialog) => AlertDialog(
                                title: Text(context.tr('开启图片收藏互通？')),
                                content: Text(
                                  context.tr(
                                    '之后收藏或取消图片时，PhotoTree 会同步更新系统收藏。手机自带相册是否显示这些更改取决于它是否使用系统收藏标记。已有应用内收藏可另行选择迁移。',
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(dialog, false),
                                    child: Text(context.tr('取消')),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(dialog, true),
                                    child: Text(context.tr('开启')),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed != true || !context.mounted) return;
                          }
                          if (!await favorites.setImageSync(value) &&
                              context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(context.tr('设置未更改，请刷新后重试')),
                              ),
                            );
                          }
                        }
                      : null,
                ),
              ),
              ListenableBuilder(
                listenable: favorites,
                builder: (context, _) => favorites.systemMode
                    ? _BrowseEntry(
                        title: context.tr('迁移已有图片收藏'),
                        icon: Icons.favorite_outline,
                        onTap: () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) =>
                                FavoriteMigrationPage(favorites: favorites),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        if (widget.backup != null && widget.restore != null)
          _BrowseSection(
            title: context.tr('应用数据'),
            children: [
              _BrowseEntry(
                title: context.tr('备份与恢复'),
                subtitle: context.tr('导出、恢复、处理待关联记录与回滚'),
                icon: Icons.settings_backup_restore,
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => BackupHomePage(
                      backup: widget.backup!,
                      restore: widget.restore!,
                    ),
                  ),
                ),
              ),
            ],
          ),
        if (kDebugMode)
          _BrowseSection(
            title: context.tr('开发验证'),
            children: [
              _BrowseEntry(
                title: context.tr('动效验证'),
                subtitle: context.tr('独立示例 · 不读取媒体'),
                icon: Icons.touch_app_outlined,
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (context) => const MotionProbePage(),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _BrowseSection extends StatelessWidget {
  const _BrowseSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          GlassSurface(
            highOpacity: true,
            child: Column(
              children: [
                for (var index = 0; index < children.length; index++) ...[
                  if (index > 0)
                    const Divider(height: 1, indent: 64, endIndent: 16),
                  children[index],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DensityMenuEntry extends PopupMenuEntry<String> {
  const _DensityMenuEntry({required this.density});
  final GridDensity density;
  @override
  double get height => 84;
  @override
  bool represents(String? value) => false;
  @override
  State<_DensityMenuEntry> createState() => _DensityMenuEntryState();
}

class _DensityMenuEntryState extends State<_DensityMenuEntry> {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Popup routes use intrinsic sizing; derive this from the same screen
    // constraint as the parent instead of adding a LayoutBuilder here.
    final vertical =
        context.usesEnglish ||
        MediaQuery.sizeOf(context).width < 340 ||
        MediaQuery.textScalerOf(context).scale(13) > 18;
    Widget option(GridDensity density) {
      final selected = density == widget.density;
      final label = switch (density) {
        GridDensity.comfortable => context.tr('舒适'),
        GridDensity.compact => context.tr('紧凑'),
        GridDensity.dense => context.tr('密集'),
      };
      final color = selected ? colors.primary : colors.onSurfaceVariant;
      final columns = density.index + 3;
      final glyph = SizedBox(
        width: 22,
        height: 16,
        child: Column(
          children: [
            for (var row = 0; row < columns - 1; row++) ...[
              if (row > 0) const SizedBox(height: 2),
              Expanded(
                child: Row(
                  children: [
                    for (var col = 0; col < columns; col++) ...[
                      if (col > 0) const SizedBox(width: 2),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      );
      final text = Text(
        label,
        style: TextStyle(
          fontSize: 13,
          height: 18 / 13,
          fontWeight: FontWeight.w500,
          color: selected ? colors.primary : colors.onSurface,
        ),
      );
      return Semantics(
        label: context.tr('{0}网格', [label]),
        selected: selected,
        button: true,
        child: Material(
          color: selected ? colors.primaryContainer : colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: selected
                  ? colors.primary.withValues(alpha: .4)
                  : colors.onSurface.withValues(alpha: .10),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('density-${density.name}'),
            onTap: () => Navigator.pop(context, density.name),
            child: ExcludeSemantics(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: vertical ? 6 : 4,
                  ),
                  child: vertical
                      ? Row(
                          children: [
                            glyph,
                            const SizedBox(width: 12),
                            Expanded(child: text),
                            SizedBox(
                              width: 16,
                              child: selected
                                  ? Icon(
                                      Icons.check_rounded,
                                      size: 16,
                                      color: color,
                                    )
                                  : null,
                            ),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            glyph,
                            const SizedBox(height: 2),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                text,
                                if (selected) ...[
                                  const SizedBox(width: 2),
                                  Icon(
                                    Icons.check_rounded,
                                    size: 12,
                                    color: color,
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 4),
            child: Text(
              context.tr('网格密度'),
              style: TextStyle(
                fontSize: 12,
                height: 17 / 12,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          if (vertical)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final density in GridDensity.values) ...[
                  if (density.index > 0) const SizedBox(height: 8),
                  option(density),
                ],
              ],
            )
          else
            Row(
              children: [
                for (final density in GridDensity.values) ...[
                  if (density.index > 0) const SizedBox(width: 4),
                  Expanded(child: option(density)),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _BrowseEntry extends StatelessWidget {
  const _BrowseEntry({
    required this.title,
    required this.icon,
    required this.onTap,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: const Icon(Icons.chevron_right_rounded, size: 22),
      onTap: onTap,
    );
  }
}

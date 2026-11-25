import 'dart:io';

import 'storage/interface_language.dart';
import 'ui/language_setting.dart';

import 'storage/android_directory_access.dart';
import 'backup/android_backup_adapter.dart';
import 'backup/backup_export.dart';
import 'backup/backup_restore.dart';
import 'backup/restore_journal.dart';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

import 'ui/library_shell.dart';
import 'ui/thumbnail_images.dart';
import 'organization/organization.dart';
import 'organization/sqlite_organization_store.dart';
import 'dev/acceptance_trace.dart';
import 'library/favorites.dart';
import 'library/sqlite_favorite_store.dart';
import 'library/physical_operations.dart';
import 'library/sqlite_physical_journal.dart';
import 'media/physical_media.dart';
import 'media/browser.dart';
import 'media/android_media_source.dart';
import 'media/android_system_favorites.dart';
import 'storage/sidebar_preferences.dart';

class PhotoTreeApp extends StatefulWidget {
  const PhotoTreeApp({super.key});

  @override
  State<PhotoTreeApp> createState() => _PhotoTreeAppState();
}

class _PhotoTreeAppState extends State<PhotoTreeApp>
    with WidgetsBindingObserver {
  late final PhotoBrowser browser;
  late final ThumbnailImages thumbnails;
  late final Favorites favorites;
  late final Organization organization;
  late final BackupExport backup;
  late final BackupRestore restore;
  late final PhysicalOperations physical;
  late final AndroidDirectoryAccess directoryAccess;
  late final SidebarPreferences sidebarPreferences;
  late final InterfaceLanguageStore languageStore;
  int _cacheGeneration = -1;
  bool _loadingPrivateData = false;
  void _onMediaChanged() {
    if (browser.phase == BrowsePhase.ready &&
        (favorites.systemRequestPending || !restore.initialized)) {
      _loadPrivateData();
    }
    if (acceptanceTraceEnabled && browser.phase == BrowsePhase.ready) {
      acceptanceTrace.expectStartupKeys(browser.photos.map((p) => p.key));
    }
    if (_cacheGeneration == browser.imageGeneration) return;
    _cacheGeneration = browser.imageGeneration;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  @override
  void initState() {
    super.initState();
    languageStore = InterfaceLanguageStore(
      () async => Directory(await getDatabasesPath()),
    );
    sidebarPreferences = SidebarPreferences(
      directory: () async => Directory(await getDatabasesPath()),
    );
    PaintingBinding.instance.imageCache.maximumSizeBytes = 48 * 1024 * 1024;
    PaintingBinding.instance.imageCache.maximumSize = 120;
    browser = PhotoBrowser(AndroidMediaSource());
    thumbnails = ThumbnailImages(browser);
    final guard = BackupOperationGuard();
    final favoriteStore = SqliteFavoriteStore();
    favorites = Favorites(
      favoriteStore,
      syncStore: favoriteStore,
      browser,
      // The normal APK requires Android API 30, which provides favorite requests.
      system: AndroidSystemFavorites(requestsSupported: true),
      guard: guard,
    );
    directoryAccess = AndroidDirectoryAccess();
    organization = Organization(
      SqliteOrganizationStore(),
      browser,
      directories: directoryAccess,
      operationGuard: guard,
    );
    final adapter = AndroidBackupAdapter();
    backup = BackupExport(
      organization,
      favorites,
      browser,
      adapter,
      adapter,
      guard: guard,
    );
    restore = BackupRestore(
      organization,
      favorites,
      browser,
      adapter,
      adapter,
      adapter,
      SqliteRestoreJournal(),
      guard: guard,
    );
    physical = PhysicalOperations(
      organization,
      favorites,
      browser,
      AndroidPhysicalMediaAccess(),
      SqlitePhysicalJournal(),
      guard: guard,
    );
    restore.addListener(_restoreChanged);
    favorites.addListener(_favoritesChanged);
    _loadPrivateData();
    browser.addListener(_onMediaChanged);
    WidgetsBinding.instance.addObserver(this);
    browser.refresh();
  }

  Future<void> _loadPrivateData() async {
    if (_loadingPrivateData || !mounted) return;
    _loadingPrivateData = true;
    try {
      // A recreated engine must not restore private data while an earlier
      // Activity still owns a system favorite request in this process.
      if (!await favorites.reconcileSystemRequest() || !mounted) return;
      if (!restore.initialized && !restore.busy && !restore.blocked) {
        await restore.initialize();
      }
      _restoreChanged();
    } finally {
      _loadingPrivateData = false;
    }
  }

  void _favoritesChanged() {
    if (!favorites.systemRequestPending && !restore.initialized) {
      _loadPrivateData();
    }
  }

  void _restoreChanged() {
    if (mounted &&
        restore.initialized &&
        !restore.busy &&
        !restore.blocked &&
        !physical.initialized &&
        !physical.busy &&
        !physical.blocked) {
      physical.initialize();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadPrivateData();
      browser.refresh();
      organization.refreshDirectories();
    }
    if (state == AppLifecycleState.inactive) {
      browser.suspend();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    restore.removeListener(_restoreChanged);
    favorites.removeListener(_favoritesChanged);
    physical.dispose();
    restore.dispose();
    organization.dispose();
    favorites.dispose();
    thumbnails.dispose();
    browser.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InterfaceLanguageApp(
      store: languageStore,
      home: ThumbnailScope(
        images: thumbnails,
        child: LibraryShell(
          browser: browser,
          favorites: favorites,
          organization: organization,
          backup: backup,
          restore: restore,
          physical: physical,
          directoryAccess: directoryAccess,
          readSidebarOpacity: sidebarPreferences.readOpacity,
          saveSidebarOpacity: sidebarPreferences.writeOpacity,
        ),
      ),
    );
  }
}

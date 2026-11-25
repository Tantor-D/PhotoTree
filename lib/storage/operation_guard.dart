import 'package:flutter/foundation.dart';

/// Explicitly shared by physical creation, classification export and restore.
class BackupOperationGuard extends ChangeNotifier {
  Object? _owner;
  bool get held => _owner != null;
  void acquire(Object owner) {
    if (_owner != null) throw StateError('另一项媒体、备份或恢复操作正在进行');
    _owner = owner;
    notifyListeners();
  }

  void release(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    notifyListeners();
  }
}

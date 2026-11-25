import 'package:flutter/services.dart';

import 'directory_access.dart';

class AndroidDirectoryAccess implements PhysicalDirectoryAccess {
  AndroidDirectoryAccess({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('io.github.tantor_d.phototree/directories');
  final MethodChannel _channel;
  @override
  Future<DirectoryReading> readDirectory(DirectoryIdentity directory) async {
    if (!directory.supported) {
      return const DirectoryReading(DirectoryContents.failed, '不支持此目录');
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'readDirectory',
        _args(directory),
      );
      final kind = DirectoryContents.values
          .where((v) => v.name == result?['contents'])
          .firstOrNull;
      if (kind == null) {
        throw const FormatException('Invalid directory response');
      }
      return DirectoryReading(kind, result?['reason'] as String? ?? '目录状态待核对');
    } catch (_) {
      return const DirectoryReading(DirectoryContents.failed, '目录查询失败，状态待核对');
    }
  }

  @override
  Future<String?> begin(DirectoryIdentity directory) async {
    if (!directory.supported) return null;
    try {
      return await _channel.invokeMethod<String>('begin', _args(directory));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<DirectoryCreationResult> create(String token, String name) async {
    try {
      final result = await _channel.invokeMethod<String>('create', {
        'token': token,
        'name': name,
      });
      return DirectoryCreationResult.values
              .where((v) => v.name == result)
              .firstOrNull ??
          DirectoryCreationResult.unknown;
    } catch (_) {
      return DirectoryCreationResult.unknown;
    }
  }

  @override
  Future<bool> verify(String token) async {
    try {
      return await _channel.invokeMethod<bool>('verify', {'token': token}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> end(String token) async {
    try {
      await _channel.invokeMethod<Object?>('end', {'token': token});
    } catch (_) {
      /* Engine cleanup also closes the handle. */
    }
  }

  Map<String, String> _args(DirectoryIdentity d) => {
    'volume': d.volume,
    'path': d.path,
  };
  @override
  Future<DirectoryCapabilities> inspect(DirectoryIdentity directory) async {
    if (!directory.supported) {
      return const DirectoryCapabilities(
        status: DirectoryStatus.unsupported,
        reason: '仅支持主共享存储 Pictures/ 或 DCIM/ 内的规范目录',
      );
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'inspect',
        _args(directory),
      );
      final status = DirectoryStatus.values
          .where((s) => s.name == raw?['status'])
          .firstOrNull;
      if (status == null) {
        throw const FormatException('Unknown directory status');
      }
      // Inspection is not a live exclusive-creation credential.
      return DirectoryCapabilities(
        status: status,
        reason: raw?['reason'] as String? ?? '无法确认目录',
        readable: raw?['readable'] == true,
        listable: raw?['listable'] == true,
        create: SafePrimitive.unknown,
        move: SafePrimitive.unsupported,
        deleteEmpty: SafePrimitive.unsupported,
      );
    } catch (_) {
      return const DirectoryCapabilities(
        status: DirectoryStatus.unavailable,
        reason: '无法确认目录状态，请重试',
      );
    }
  }

  @override
  Future<DirectoryRequest> authorize(DirectoryIdentity directory) async {
    if (!directory.supported) return DirectoryRequest.rejected;
    try {
      final answer = await _channel.invokeMethod<String>(
        'authorize',
        _args(directory),
      );
      return DirectoryRequest.values
              .where((s) => s.name == answer)
              .firstOrNull ??
          DirectoryRequest.interrupted;
    } on PlatformException catch (e) {
      return e.code == 'busy'
          ? DirectoryRequest.busy
          : DirectoryRequest.interrupted;
    } catch (_) {
      return DirectoryRequest.interrupted;
    }
  }
}

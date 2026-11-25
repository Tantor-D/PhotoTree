import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/storage/directory_access.dart';
import 'package:phototree/ui/directory_access_page.dart';
import 'package:phototree/ui/visual_style.dart';

class PageDirectoryAccess implements DirectoryAccess {
  DirectoryStatus status = DirectoryStatus.available;
  DirectoryRequest result = DirectoryRequest.granted;
  int inspections = 0, requests = 0;
  @override
  Future<DirectoryCapabilities> inspect(DirectoryIdentity directory) async {
    inspections++;
    return DirectoryCapabilities(
      status: status,
      reason: status == DirectoryStatus.available
          ? '目录授权有效，可读取和列举；路径相同不证明目录对象未被替换'
          : '目录授权不可用，请重新选择完整路径对应的目录',
      readable: status == DirectoryStatus.available,
      listable: status == DirectoryStatus.available,
    );
  }

  @override
  Future<DirectoryRequest> authorize(DirectoryIdentity directory) async {
    requests++;
    return result;
  }
}

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'permission page stays readable and actionable in $brightness at $scale',
        (t) async {
          t.view.physicalSize = const Size(320, 640);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          final access = PageDirectoryAccess();
          const path = 'DCIM/很长的目录名Creative用于检查路径自动换行/';
          await t.pumpWidget(
            MaterialApp(
              theme: photoTreeTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: DirectoryAccessPage(
                directory: const DirectoryIdentity('external_primary', path),
                access: access,
              ),
            ),
          );
          await t.pumpAndSettle();
          expect(find.text(path), findsOneWidget);
          await t.scrollUntilVisible(find.text('目录已授权'), 200);
          expect(find.text('目录已授权'), findsOneWidget);
          await t.scrollUntilVisible(find.text('读取：可用'), 150);
          expect(find.text('读取：可用'), findsOneWidget);
          final recheck = find.widgetWithText(TextButton, '重新核对');
          await t.scrollUntilVisible(recheck, 200);
          expect(t.getSize(recheck).height, greaterThanOrEqualTo(48));
          await t.tap(recheck);
          await t.pumpAndSettle();
          expect(access.inspections, 2);
          final explanation = find.text('权限说明');
          await t.scrollUntilVisible(explanation, 200);
          await t.tap(explanation);
          await t.pumpAndSettle();
          final detail = find.textContaining('路径相同不证明');
          await t.scrollUntilVisible(detail, 200);
          expect(detail, findsOneWidget);
          expect(t.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'unavailable states and cancelled authorization do not show success',
    (t) async {
      final access = PageDirectoryAccess()..result = DirectoryRequest.cancelled;
      for (final status in DirectoryStatus.values.where(
        (s) => s != DirectoryStatus.available,
      )) {
        access.status = status;
        await t.pumpWidget(
          MaterialApp(
            theme: photoTreeTheme(Brightness.light),
            home: DirectoryAccessPage(
              key: ValueKey(status),
              directory: const DirectoryIdentity(
                'external_primary',
                'DCIM/Creative/',
              ),
              access: access,
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('目录已授权'), findsNothing);
        expect(find.text('读取：不可用'), findsOneWidget);
        expect(find.text('目录授权不可用，请重新选择完整路径对应的目录'), findsOneWidget);
        await t.tap(find.text('选择目录授权'));
        await t.pumpAndSettle();
        expect(find.text('已取消授权，未更改媒体'), findsOneWidget);
        expect(find.text('目录已授权'), findsNothing);
        expect(t.takeException(), isNull);
      }
      expect(access.requests, 4);
    },
  );
}

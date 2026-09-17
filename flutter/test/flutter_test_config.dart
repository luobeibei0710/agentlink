import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 让测试渲染出**可读的文字与图标**。
///
/// flutter_test 默认只带一个占位字体，每个字形都画成实心方块 —— 渲染快照因此只能
/// 比对「哪里多了一块」，人眼看不出界面到底对不对，也没法拿它们当文档截图。
///
/// 这里加载两样东西：
///
/// - **正文与代码字体**：仓库内置的中文字体子集（约 200KB），注册成应用实际使用的
///   两个族名 —— `sans-serif`（`agentlink_theme.dart`）与 `monospace`
///   （`message_views.dart`）。来源与许可见 `test/fonts/LICENSE-OFL.txt`。
/// - **Material 图标**：直接从 Flutter SDK 里取，不重复入库。SDK 找不到时退回方块图标
///   并打印提示 —— 那属于环境问题，不该让全部测试直接失败。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final textFont = File('test/fonts/NotoSansSC-Subset.otf');
  if (!textFont.existsSync()) {
    // 直接报错而不是静默跳过：少了它，快照会悄悄退化成方块图，比对依然"通过"，
    // 但再也没有人看得出差异。
    throw StateError(
      '缺少渲染字体：${textFont.path}（工作目录应为 flutter/）。',
    );
  }
  final textBytes = ByteData.sublistView(textFont.readAsBytesSync());
  for (final family in const ['sans-serif', 'monospace']) {
    await (FontLoader(family)..addFont(Future.value(textBytes))).load();
  }

  final iconFont = _locateMaterialIcons();
  if (iconFont == null) {
    // ignore: avoid_print
    print('提示：没找到 Flutter SDK 的 Material 图标字体，快照里的图标会是方块。');
  } else {
    final iconBytes = ByteData.sublistView(iconFont.readAsBytesSync());
    await (FontLoader('MaterialIcons')..addFont(Future.value(iconBytes))).load();
  }

  await testMain();
}

/// 从测试进程的位置往上找 Flutter SDK 里的 Material 图标字体。
///
/// 测试跑在 `<sdk>/bin/cache/artifacts/engine/<平台>/flutter_tester` 里，往上三层
/// 就是 `artifacts/`，图标字体放在它的 `material_fonts/` 下。
File? _locateMaterialIcons() {
  var dir = File(Platform.resolvedExecutable).parent;
  for (var depth = 0; depth < 5; depth++) {
    final candidate = File('${dir.path}/material_fonts/MaterialIcons-Regular.otf');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

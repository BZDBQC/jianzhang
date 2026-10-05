// dart format width=140
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jianzhang/app/controller.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/main.dart';
import 'package:jianzhang/ui/entry_form.dart';
import 'package:jianzhang/ui/search_form.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef _FindNative = IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>);
typedef _Find = int Function(int, int, Pointer<Utf16>, Pointer<Utf16>);
typedef _OwnerNative = Uint32 Function(IntPtr, Pointer<Uint32>);
typedef _Owner = int Function(int, Pointer<Uint32>);
typedef _RectNative = Int32 Function(IntPtr, Pointer<Int32>);
typedef _Rect = int Function(int, Pointer<Int32>);
typedef _PositionNative = Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32);
typedef _Position = int Function(int, int, int, int, int, int, int);

class _OwnedWindow {
  final _user = DynamicLibrary.open('user32.dll');
  late final _find = _user.lookupFunction<_FindNative, _Find>('FindWindowExW');
  late final _owner = _user.lookupFunction<_OwnerNative, _Owner>('GetWindowThreadProcessId');
  late final _outer = _user.lookupFunction<_RectNative, _Rect>('GetWindowRect');
  late final _client = _user.lookupFunction<_RectNative, _Rect>('GetClientRect');
  late final _position = _user.lookupFunction<_PositionNative, _Position>('SetWindowPos');
  late final dpi = _user.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('GetDpiForWindow');
  final _lastError = DynamicLibrary.open('kernel32.dll').lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  late final int handle = _findOwn();

  int _findOwn() {
    final name = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    try {
      var previous = 0;
      while (true) {
        final next = _find(0, previous, name, nullptr);
        if (next == 0) {
          throw StateError('This process has no Flutter runner window');
        }
        if (owns(next)) return next;
        previous = next;
      }
    } finally {
      calloc.free(name);
    }
  }

  bool owns(int candidate) => using((arena) {
    final owner = arena<Uint32>();
    return _owner(candidate, owner) != 0 && owner.value == pid;
  });
  Rect rect({bool client = false}) => using((arena) {
    if (!owns(handle)) throw StateError('Window ownership changed');
    final values = arena<Int32>(4);
    if ((client ? _client : _outer)(handle, values) == 0) {
      throw StateError('Reading window bounds failed: ${_lastError()}');
    }
    return Rect.fromLTRB(values[0].toDouble(), values[1].toDouble(), values[2].toDouble(), values[3].toDouble());
  });
  void resize(Size size) {
    if (!owns(handle)) {
      throw StateError('Refusing to resize a different process');
    }
    // ASYNCWINDOWPOS | NOMOVE | NOZORDER | NOACTIVATE; no global DPI changes.
    if (_position(handle, 0, 0, 0, size.width.toInt(), size.height.toInt(), 0x4016) == 0) {
      throw StateError('Resizing test window failed: ${_lastError()}');
    }
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('native Windows keyboard, current DPI and real window resizing', (tester) async {
    expect(Platform.isWindows && (kProfileMode || kReleaseMode), isTrue);
    const build = String.fromEnvironment('JIANZHANG_QA_BUILD');
    const round = String.fromEnvironment('JIANZHANG_QA_ROUND');
    for (final id in [build, round]) {
      expect(RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id), isTrue);
      expect(id, isNot(isIn(['manual', 'unassigned'])));
    }
    final parent = await Directory(p.join((await getTemporaryDirectory()).path, 'jianzhang-windows-qa')).create(recursive: true);
    final output = await parent.createTemp('run-');
    final repository = await LedgerRepository.open(path: p.join(output.path, 'ledger.sqlite'));
    final window = _OwnedWindow(), original = window.rect(), capture = GlobalKey();
    final report = <String, Object?>{
      'buildId': build,
      'roundId': round,
      'pid': pid,
      'mode': kProfileMode ? 'profile' : 'release',
      'os': Platform.operatingSystemVersion,
      'output': output.path,
      'originalOuter': [original.left, original.top, original.width, original.height],
      'samples': <Object?>[],
      'keyboardInput': 'Flutter hardware-key dispatch; no physical/system keyboard injection',
      'dpiCoverage': 'Current monitor DPI only; no OS DPI changes',
    };
    Object? failure;
    StackTrace? failureStack;

    Future<void> synchronize(Size requested) async {
      final timeout = Stopwatch()..start();
      while (timeout.elapsed < const Duration(seconds: 5)) {
        await tester.pump(const Duration(milliseconds: 50));
        final client = window.rect(client: true);
        if (window.rect().size == requested && tester.view.physicalSize == client.size) {
          await tester.pumpAndSettle();
          return;
        }
      }
      throw StateError(
        'Native/Flutter window sizes did not converge: ${window.rect()} / ${window.rect(client: true)} / ${tester.view.physicalSize}',
      );
    }

    Future<void> mount() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWith((ref) => repository)],
          child: RepaintBoundary(key: capture, child: const JianzhangApp()),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> screenshot(String name) async {
      await tester.pumpAndSettle();
      final raster = await (capture.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(
        pixelRatio: tester.view.devicePixelRatio,
      );
      try {
        final bytes = await raster.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw StateError('PNG encoding failed');
        await File(
          p.join(output.path, '$name.png'),
        ).writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes), flush: true);
      } finally {
        raster.dispose();
      }
    }

    Future<void> shortcut(LogicalKeyboardKey key, PhysicalKeyboardKey physical) async {
      const control = PhysicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft, physicalKey: control, platform: 'windows');
      try {
        await tester.sendKeyEvent(key, physicalKey: physical, platform: 'windows');
      } finally {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft, physicalKey: control, platform: 'windows');
      }
      await tester.pumpAndSettle();
    }

    Future<void> checkLayout(String name) async {
      final add = find.byKey(const Key('add-entry'));
      final bounds = tester.getRect(add), viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(bounds.width, greaterThanOrEqualTo(48));
      expect(bounds.height, greaterThanOrEqualTo(48));
      expect(bounds.left >= 0 && bounds.top >= 0 && bounds.right <= viewport.width && bounds.bottom <= viewport.height, isTrue);
      expect(add.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await screenshot('$name-home');
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byType(EntryForm), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape, physicalKey: PhysicalKeyboardKey.escape, platform: 'windows');
      await tester.pumpAndSettle();
      expect(find.byType(EntryForm), findsNothing);
      for (final (key, physical, type, label) in [
        (LogicalKeyboardKey.keyN, PhysicalKeyboardKey.keyN, EntryForm, 'entry'),
        (LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF, SearchForm, 'search'),
      ]) {
        await shortcut(key, physical);
        expect(find.byType(type), findsOneWidget);
        await screenshot('$name-$label');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape, physicalKey: PhysicalKeyboardKey.escape, platform: 'windows');
        await tester.pumpAndSettle();
        expect(find.byType(type), findsNothing);
      }
      expect(tester.takeException(), isNull);
    }

    try {
      final leaf = (await repository.listCategories(type: EntryType.expense)).firstWhere((c) => c.parentId != null);
      await repository.saveTransaction(
        LedgerTransaction(
          id: 'layout-sample',
          type: EntryType.expense,
          amount: 123456789,
          date: localDateTime(),
          createdAt: localDateTime(),
          accountId: (await repository.listAccounts()).first.id,
          categoryId: leaf.id,
          note: '一条较长的备注，用来核对窄屏与大字体显示，包含中文、账户说明和金额。',
        ),
        create: true,
      );
      await mount();
      for (final size in const [Size(640, 520), Size(1024, 720), Size(1600, 1000)]) {
        window.resize(size);
        await synchronize(size);
        final dpi = window.dpi(window.handle), dpr = tester.view.devicePixelRatio;
        expect(dpi, greaterThan(0));
        expect(dpr.isFinite && dpr > 0, isTrue);
        expect(dpr, closeTo(dpi / 96, 0.02), reason: 'Native window DPI and Flutter scaling must agree');
        (report['samples'] as List).add({
          'requestedOuter': [size.width, size.height],
          'actualClient': [window.rect(client: true).width, window.rect(client: true).height],
          'flutterPhysical': [tester.view.physicalSize.width, tester.view.physicalSize.height],
          'dpi': dpi,
          'devicePixelRatio': dpr,
          'textScale': MediaQuery.textScalerOf(tester.element(find.byKey(const Key('add-entry')))).scale(10) / 10,
          'logicalViewport': [tester.view.physicalSize.width / dpr, tester.view.physicalSize.height / dpr],
        });
        await checkLayout('${size.width.toInt()}x${size.height.toInt()}');
      }
      expect((await repository.meta()).transactionCount, 1);
      expect((await repository.summary()).expense, 123456789);
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
      report['error'] = '$error';
    } finally {
      try {
        window.resize(original.size);
        await synchronize(original.size);
        report['restoredOuter'] = [window.rect().width, window.rect().height];
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
        report['restoreError'] = '$error';
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await repository.close();
      report['passed'] = failure == null;
      await File(p.join(output.path, 'evidence.json')).writeAsString(jsonEncode(report), flush: true);
      debugPrint('JIANZHANG_WINDOWS_ADAPTATION=${jsonEncode(report)}');
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack!);
    }
  });
}

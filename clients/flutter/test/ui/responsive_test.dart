import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/app/theme.dart';
import 'package:jianzhang/ui/common.dart';

void main() {
  for (final width in [360.0, 390.0, 412.0, 600.0, 1280.0]) {
    testWidgets('page heading fits $width pixels with large text', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: const TextScaler.linear(1.6),
            ),
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: SectionHeading(
                  title: '每一笔都清楚，每一天都从容',
                  caption: '无需登录，账单安全保存在此设备。',
                  action: FilledButton(
                    onPressed: () {},
                    child: const Text('记一笔'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(FilledButton)).height,
        greaterThanOrEqualTo(48),
      );
    });
  }

  test('normal text and action colors meet AA contrast', () {
    double contrast(Color foreground, Color background) {
      final a = foreground.computeLuminance();
      final b = background.computeLuminance();
      return (a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05));
    }

    expect(contrast(AppColors.muted, Colors.white), greaterThanOrEqualTo(4.5));
    expect(
      contrast(AppColors.muted, AppColors.background),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      contrast(Colors.white, AppColors.primary),
      greaterThanOrEqualTo(4.5),
    );
  });

  testWidgets('long form remains scrollable with the keyboard visible', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => FormDialog(
                  title: '新增账单',
                  actions: [
                    FilledButton(onPressed: () {}, child: const Text('保存账单')),
                  ],
                  children: List.generate(
                    12,
                    (index) => Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: TextFormField(
                        decoration: InputDecoration(labelText: '字段 $index'),
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('打开表单'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开表单'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -1800),
    );
    await tester.pumpAndSettle();
    expect(find.text('保存账单').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

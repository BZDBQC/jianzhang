import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/controller.dart';
import 'app/startup_configuration.dart';
import 'app/theme.dart';
import 'ui/shell.dart';

void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  // A requested but invalid fixture must fail before any database provider runs.
  final startup = StartupConfiguration.resolve(arguments);
  final path = startup.databasePath;
  if (path != null) {
    stdout.writeln(
      'JIANZHANG_QA_DATABASE ${jsonEncode({'databasePath': path, 'runId': startup.runId, 'sample': startup.sample, 'initialTransactions': 0})}',
    );
  }
  runApp(
    ProviderScope(
      overrides: [
        if (path != null) initialDatabasePathProvider.overrideWithValue(path),
      ],
      child: const JianzhangApp(),
    ),
  );
}

class JianzhangApp extends StatelessWidget {
  const JianzhangApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '简账',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: const LedgerShell(),
  );
}

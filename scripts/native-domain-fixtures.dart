import 'dart:convert';
import 'dart:io';

import '../clients/flutter/lib/domain/ledger_models.dart';
import '../clients/flutter/lib/data/json_stream.dart';

Future<void> main() async {
  final fixture = jsonObject(
    jsonDecode(
      await File('tests/fixtures/native-domain-v1.json').readAsString(),
    ),
  );
  final ledger = jsonObject(fixture['ledger']);
  final tx = (ledger['transactions'] as List)
      .map(LedgerTransaction.fromJson)
      .toList();
  final categories = (ledger['categories'] as List)
      .map(Category.fromJson)
      .toList();
  if (jsonEncode(summarize(tx).toJson()) != jsonEncode(fixture['summary']))
    throw StateError('Summary mismatch');
  for (final raw in fixture['filters'] as List) {
    final row = jsonObject(raw);
    final ids = tx
        .where(
          (t) => matches(
            t,
            LedgerFilter.fromJson(jsonObject(row['filter'])),
            categories,
          ),
        )
        .map((t) => t.id)
        .toList();
    if (jsonEncode(ids) != jsonEncode(row['ids']))
      throw StateError('Filter mismatch: ${row['filter']}');
  }
  final reader = JsonStreamReader(
    File('tests/fixtures/native-ledger-v1.json').openRead(),
  );
  var count = 0;
  try {
    await reader.root((key, value) async {}, (key, value) async {
      if (key == 'transactions') count++;
    });
  } finally {
    await reader.close();
  }
  if (count != tx.length) throw StateError('Streaming reader mismatch');
  stdout.writeln(
    'domain shared fixture + streaming parser passed; Unicode lower=${'ÉCOLE Σ'.toLowerCase()}',
  );
}

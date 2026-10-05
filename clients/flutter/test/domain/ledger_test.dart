import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/domain/ledger_models.dart';

void main() {
  test(
    'Unicode lowercase matches Node full casing and sigma context golden',
    () {
      final fixture =
          jsonDecode(
                File(
                  '../../tests/fixtures/native-unicode-v1.json',
                ).readAsStringSync(),
              )
              as Map;
      for (final sample in fixture['samples'] as List) {
        expect(unicodeLower(sample['value'] as String), sample['lower']);
      }
    },
  );
  test('money uses exact cents and valid calendar minutes', () {
    expect(parseMoney('0.10'), 10);
    expect(parseMoney('999999999.99'), maxMoney);
    for (final s in ['-1', '0', '1.234', '1e2', 'NaN']) {
      expect(() => parseMoney(s), throwsA(isA<LedgerException>()));
    }
    expect(validDate('2024-02-29T23:59'), true);
    expect(validDate('2026-02-29T23:59'), false);
    expect(validDate('2026-01-01T24:00'), false);
  });
  test('node shared fixture preserves money and transfer conservation', () {
    final fixture =
        jsonDecode(
              File(
                '../../tests/fixtures/native-domain-v1.json',
              ).readAsStringSync(),
            )
            as Map;
    final ledger = fixture['ledger'] as Map;
    final tx = (ledger['transactions'] as List)
        .map(LedgerTransaction.fromJson)
        .toList();
    expect(summarize(tx).toJson(), fixture['summary']);
    for (final raw in ledger['accounts'] as List) {
      final account = Account.fromJson(raw);
      expect(
        accountBalance(account, tx),
        (fixture['balances'] as Map)[account.id],
      );
    }
  });
  test(
    'signed openings and UTF-16 limits preserve the legacy JSON contract',
    () {
      const account = Account(
        id: 'debt',
        name: '债务',
        openingBalance: -maxMoney,
      );
      account.validate();
      expect(accountBalance(account, const []), -maxMoney);
      final note = List.filled(1000, '😀').join();
      expect(note.length, 2000);
      final tx = LedgerTransaction(
        id: 'emoji',
        type: EntryType.expense,
        amount: 1,
        date: '2026-10-01T00:00',
        createdAt: '2026-10-01T00:00',
        accountId: 'debt',
        categoryId: 'food-lunch',
        note: note,
      );
      tx.validate();
      expect(
        () => tx.copyWith(note: '$note😀').validate(),
        throwsA(isA<LedgerException>()),
      );
      expect(
        () => validateId(List.filled(51, '😀').join()),
        throwsA(isA<LedgerException>()),
      );
    },
  );
}

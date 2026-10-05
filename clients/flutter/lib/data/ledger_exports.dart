import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/ledger_models.dart';
import 'safe_files.dart';

const exportHeaders = [
  '类型',
  '金额（元）',
  '日期时间',
  '大类',
  '小类',
  '账户 / 转出账户',
  '转入账户',
  '手续费（元）',
  '备注',
];
String numericMoney(int cents) {
  final s = decimalMoney(cents);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

String _csv(Object? value) {
  var s = value?.toString() ?? '';
  if (RegExp(r'^\s*[=+\-@]').hasMatch(s)) s = "'$s";
  return '"${s.replaceAll('"', '""')}"';
}

String _xml(Object? value) => value
    .toString()
    .replaceAll(RegExp('[\x00-\x08\x0b\x0c\x0e-\x1f\uFFFE\uFFFF]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
List<Object> exportRow(
  LedgerTransaction t,
  Map<String, Account> accounts,
  Map<String, Category> categories,
) {
  final c = categories[t.categoryId];
  return [
    switch (t.type) {
      EntryType.expense => '支出',
      EntryType.income => '收入',
      EntryType.transfer => '转账',
    },
    numericMoney(t.amount),
    t.date.replaceFirst('T', ' '),
    categories[c?.parentId]?.name ?? '',
    c?.name ?? '',
    accounts[t.accountId]?.name ?? '',
    t.type == EntryType.transfer ? accounts[t.toAccountId]?.name ?? '' : '',
    numericMoney(t.fee),
    t.note,
  ];
}

Future<void> writeCsv(
  File target,
  Stream<LedgerTransaction> rows,
  Map<String, Account> accounts,
  Map<String, Category> categories,
) async {
  final out = target.openWrite();
  try {
    out.write('\uFEFF${exportHeaders.map(_csv).join(',')}');
    var count = 0;
    final chunk = StringBuffer();
    await for (final row in rows) {
      chunk.write(
        '\r\n${exportRow(row, accounts, categories).map(_csv).join(',')}',
      );
      if (++count % 500 == 0) {
        out.write(chunk.toString());
        chunk.clear();
        await out.flush();
      }
    }
    out.write(chunk.toString());
    await out.flush();
  } finally {
    await out.close();
  }
}

Future<void> writeXlsx(
  File target,
  Stream<LedgerTransaction> rows,
  Map<String, Account> accounts,
  Map<String, Category> categories,
) async {
  final temp = await Directory.systemTemp.createTemp('jianzhang-xlsx-');
  try {
    final sheet = File('${temp.path}/sheet.xml'), out = sheet.openWrite();
    var rowIndex = 1;
    final chunk = StringBuffer();
    void addRow(List<Object> values, {bool header = false}) {
      chunk.write('<row r="$rowIndex">');
      for (var j = 0; j < values.length; j++) {
        final ref = '${String.fromCharCode(65 + j)}$rowIndex';
        if (!header && (j == 1 || j == 7)) {
          chunk.write('<c r="$ref" s="1"><v>${values[j]}</v></c>');
        } else {
          chunk.write(
            '<c r="$ref" t="inlineStr"><is><t xml:space="preserve">${_xml(values[j])}</t></is></c>',
          );
        }
      }
      chunk.write('</row>');
      rowIndex++;
    }

    try {
      out.write(
        '<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols><col min="1" max="8" width="20" customWidth="1"/><col min="9" max="9" width="40" customWidth="1"/></cols><sheetData>',
      );
      addRow(exportHeaders, header: true);
      await for (final row in rows) {
        addRow(exportRow(row, accounts, categories));
        if (rowIndex % 500 == 0) {
          out.write(chunk.toString());
          chunk.clear();
          await out.flush();
        }
      }
      out.write(chunk.toString());
      out.write(
        '</sheetData><autoFilter ref="A1:I${rowIndex - 1}"/></worksheet>',
      );
      await out.flush();
    } finally {
      await out.close();
    }
    const files = {
      '[Content_Types].xml':
          '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>',
      '_rels/.rels':
          '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
      'xl/workbook.xml':
          '<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="简账账单" sheetId="1" r:id="rId1"/></sheets></workbook>',
      'xl/_rels/workbook.xml.rels':
          '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>',
      'xl/styles.xml':
          '<?xml version="1.0"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="2" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs></styleSheet>',
    };
    final sources = <String, File>{};
    for (final e in files.entries) {
      final file = File('${temp.path}/${sources.length}.xml');
      await file.writeAsString(e.value);
      sources[e.key] = file;
    }
    sources['xl/worksheets/sheet1.xml'] = sheet;
    await _zipStored(target, sources);
  } finally {
    await deleteOwnedScratchDirectory(temp, 'jianzhang-xlsx-');
  }
}

Future<void> _zipStored(File target, Map<String, File> files) async {
  final out = target.openWrite();
  final central = <Uint8List>[];
  var offset = 0;
  Uint8List header(int length) => Uint8List(length);
  try {
    for (final entry in files.entries) {
      final name = utf8.encode(entry.key), size = await entry.value.length();
      var crc = 0xffffffff;
      await for (final bytes in entry.value.openRead()) {
        for (final b in bytes) {
          crc ^= b;
          for (var i = 0; i < 8; i++) {
            crc = (crc >>> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
          }
        }
      }
      crc = (crc ^ 0xffffffff) & 0xffffffff;
      final h = header(30), v = ByteData.sublistView(h);
      v.setUint32(0, 0x04034b50, Endian.little);
      v.setUint16(4, 20, Endian.little);
      v.setUint32(14, crc, Endian.little);
      v.setUint32(18, size, Endian.little);
      v.setUint32(22, size, Endian.little);
      v.setUint16(26, name.length, Endian.little);
      out.add(h);
      out.add(name);
      await out.addStream(entry.value.openRead());
      final c = header(46), d = ByteData.sublistView(c);
      d.setUint32(0, 0x02014b50, Endian.little);
      d.setUint16(4, 20, Endian.little);
      d.setUint16(6, 20, Endian.little);
      d.setUint32(16, crc, Endian.little);
      d.setUint32(20, size, Endian.little);
      d.setUint32(24, size, Endian.little);
      d.setUint16(28, name.length, Endian.little);
      d.setUint32(42, offset, Endian.little);
      central.add(Uint8List.fromList([...c, ...name]));
      offset += 30 + name.length + size;
    }
    final start = offset;
    for (final c in central) {
      out.add(c);
      offset += c.length;
    }
    final end = header(22), d = ByteData.sublistView(end);
    d.setUint32(0, 0x06054b50, Endian.little);
    d.setUint16(8, files.length, Endian.little);
    d.setUint16(10, files.length, Endian.little);
    d.setUint32(12, offset - start, Endian.little);
    d.setUint32(16, start, Endian.little);
    out.add(end);
    await out.flush();
  } finally {
    await out.close();
  }
}

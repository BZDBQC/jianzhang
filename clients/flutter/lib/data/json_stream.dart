import 'dart:async';
import 'dart:convert';

import '../domain/ledger_models.dart';

/// Reads only one JSON array item at a time; transaction arrays never accumulate.
class JsonStreamReader {
  JsonStreamReader(Stream<List<int>> bytes)
    : _chunks = StreamIterator(bytes.transform(utf8.decoder));
  final StreamIterator<String> _chunks;
  String _buffer = '';
  int _position = 0;
  bool _ended = false;
  Future<String?> _peek() async {
    while (_position >= _buffer.length) {
      if (_ended) return null;
      if (!await _chunks.moveNext()) {
        _ended = true;
        return null;
      }
      _buffer = _chunks.current;
      _position = 0;
    }
    return _buffer[_position];
  }

  Future<String?> _take() async {
    final c = await _peek();
    if (c != null) _position++;
    return c;
  }

  Future<String?> _space() async {
    var c = await _peek();
    while (c != null && RegExp(r'\s').hasMatch(c)) {
      _position++;
      c = await _peek();
    }
    return c;
  }

  Future<void> expect(String value) async {
    await _space();
    if (await _take() != value) throw const LedgerException('JSON 格式不正确');
  }

  Future<Object?> value() async {
    final first = await _space();
    if (first == null) throw const LedgerException('JSON 文件不完整');
    final text = StringBuffer();
    var depth = 0, inString = false, escaped = false, finished = false;
    final structured = first == '{' || first == '[' || first == '"';
    while (true) {
      if (await _peek() == null) {
        if (inString || depth > 0) throw const LedgerException('JSON 文件不完整');
        break;
      }
      final start = _position;
      while (_position < _buffer.length) {
        final c = _buffer[_position];
        final whitespace = c == ' ' || c == '\n' || c == '\r' || c == '\t';
        if (!inString &&
            depth == 0 &&
            (text.isNotEmpty || _position > start) &&
            (c == ',' || c == ']' || c == '}' || whitespace)) {
          finished = true;
          break;
        }
        _position++;
        if (inString) {
          if (escaped) {
            escaped = false;
          } else if (c == '\\') {
            escaped = true;
          } else if (c == '"') {
            inString = false;
          }
        } else if (c == '"') {
          inString = true;
        } else if (c == '{' || c == '[') {
          depth++;
        } else if (c == '}' || c == ']') {
          depth--;
          if (depth < 0) throw const LedgerException('JSON 格式不正确');
        }
        if (!inString && depth == 0 && structured) {
          finished = true;
          break;
        }
      }
      text.write(_buffer.substring(start, _position));
      if (text.length > 4000000) throw const LedgerException('单条 JSON 数据过大');
      if (finished) break;
    }
    try {
      return jsonDecode(text.toString());
    } on FormatException {
      throw const LedgerException('JSON 格式不正确');
    }
  }

  Future<void> root(
    Future<void> Function(String, Object?) onValue,
    Future<void> Function(String, Object?) onArrayItem,
  ) async {
    await expect('{');
    final seen = <String>{};
    var first = true;
    while (await _space() != '}') {
      if (!first) await expect(',');
      first = false;
      final key = await value();
      if (key is! String || !seen.add(key)) {
        throw const LedgerException('JSON 字段重复或无效');
      }
      await expect(':');
      if (['accounts', 'categories', 'transactions', 'budgets'].contains(key)) {
        await expect('[');
        var itemFirst = true;
        while (await _space() != ']') {
          if (!itemFirst) await expect(',');
          itemFirst = false;
          await onArrayItem(key, await value());
        }
        await expect(']');
      } else {
        await onValue(key, await value());
      }
    }
    await expect('}');
    if (await _space() != null) throw const LedgerException('JSON 包含多余内容');
    if (!seen.containsAll([
      'version',
      'started',
      'accounts',
      'categories',
      'transactions',
      'budgets',
      'settings',
    ])) {
      throw const LedgerException('备份缺少必要字段');
    }
  }

  Future<void> close() => _chunks.cancel();
}

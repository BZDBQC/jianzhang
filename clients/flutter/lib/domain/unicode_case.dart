import 'unicode_case_data.dart';

final Map<int, String> _lowercase = Map.unmodifiable({
  for (final entry in lowercaseMappings.split(';').where((s) => s.isNotEmpty))
    int.parse(entry.split(':').first, radix: 16): String.fromCharCodes(
      entry.split(':').last.split(',').map((n) => int.parse(n, radix: 16)),
    ),
});
List<(int, int)> _ranges(String packed) => List.unmodifiable(
  packed.split(';').where((s) => s.isNotEmpty).map((item) {
    final parts = item.split(':');
    return (int.parse(parts[0], radix: 16), int.parse(parts[1], radix: 16));
  }),
);
final _cased = _ranges(casedRanges);
final _ignorable = _ranges(caseIgnorableRanges);
bool _contains(List<(int, int)> ranges, int code) {
  var lo = 0, hi = ranges.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) ~/ 2, range = ranges[mid];
    if (code < range.$1) {
      hi = mid - 1;
    } else if (code > range.$2) {
      lo = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

/// JavaScript String.toLowerCase semantics, including full mappings and Final_Sigma.
/// Dart's simple casing drops U+0130's dot and omits context-dependent sigma.
String unicodeLower(String value) {
  final runes = value.runes.toList(growable: false), out = StringBuffer();
  bool adjacentCased(int index, int step) {
    for (var i = index + step; i >= 0 && i < runes.length; i += step) {
      final code = runes[i];
      if (_contains(_ignorable, code)) continue;
      return _contains(_cased, code);
    }
    return false;
  }

  for (var i = 0; i < runes.length; i++) {
    final code = runes[i];
    if (code == 0x3a3 && adjacentCased(i, -1) && !adjacentCased(i, 1)) {
      out.writeCharCode(0x3c2);
    } else {
      out.write(_lowercase[code] ?? String.fromCharCode(code));
    }
  }
  return out.toString();
}

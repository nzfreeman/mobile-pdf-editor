import 'dart:typed_data';

/// Codes 0x80-0x9F under Windows-1252 (WinAnsiEncoding's upper range in
/// practice for the vast majority of real-world PDF producers). Codes
/// 0x20-0x7E and 0xA0-0xFF otherwise match Unicode/Latin-1 directly, so
/// only this 32-entry gap needs a lookup table.
const Map<int, int> _cp1252HighControlRange = {
  0x80: 0x20AC,
  0x82: 0x201A,
  0x83: 0x0192,
  0x84: 0x201E,
  0x85: 0x2026,
  0x86: 0x2020,
  0x87: 0x2021,
  0x88: 0x02C6,
  0x89: 0x2030,
  0x8A: 0x0160,
  0x8B: 0x2039,
  0x8C: 0x0152,
  0x8E: 0x017D,
  0x91: 0x2018,
  0x92: 0x2019,
  0x93: 0x201C,
  0x94: 0x201D,
  0x95: 0x2022,
  0x96: 0x2013,
  0x97: 0x2014,
  0x98: 0x02DC,
  0x99: 0x2122,
  0x9A: 0x0161,
  0x9B: 0x203A,
  0x9C: 0x0153,
  0x9E: 0x017E,
  0x9F: 0x0178,
};

/// Best-effort single-byte decode for simple (non-CID) fonts using
/// WinAnsiEncoding/StandardEncoding, both of which match Latin-1 for the
/// printable ASCII and accented-Latin ranges used by the vast majority of
/// real documents. This intentionally does not attempt full per-encoding
/// fidelity (e.g. Symbol/ZapfDingbats or exotic /Differences glyph names) —
/// documents that need that fall back to the OCR-based edit path.
String decodeSimpleByte(int code) {
  if (_cp1252HighControlRange.containsKey(code)) {
    return String.fromCharCode(_cp1252HighControlRange[code]!);
  }
  return String.fromCharCode(code);
}

String decodeSimpleBytes(Uint8List bytes) =>
    bytes.map(decodeSimpleByte).join();

/// Encodes [text] back into single-byte codes for a simple font, returning
/// null if any character can't be represented (the caller should then fall
/// back to embedding a new font or to the OCR overlay path).
Uint8List? encodeSimpleBytes(String text) {
  final out = Uint8List(text.length);
  for (var i = 0; i < text.length; i++) {
    final code = text.codeUnitAt(i);
    if (code < 0x100 && !_cp1252HighControlRange.values.contains(code)) {
      out[i] = code;
      continue;
    }
    final reverse = _cp1252HighControlRange.entries
        .where((entry) => entry.value == code)
        .map((entry) => entry.key)
        .firstOrNull;
    if (reverse == null) return null;
    out[i] = reverse;
  }
  return out;
}

/// Parses a ToUnicode CMap stream's `bfchar`/`bfrange` sections into a
/// code -> Unicode string map. This covers the common case (used by both
/// simple and Type0/CID fonts) without implementing a full CMap/PostScript
/// interpreter.
Map<int, String> parseToUnicodeCMap(String cmapSource) {
  final map = <int, String>{};

  void addBfChar(String src, String dst) {
    final code = int.tryParse(src, radix: 16);
    if (code == null) return;
    map[code] = _hexToUtf16String(dst);
  }

  final bfCharPattern = RegExp(r'beginbfchar(.*?)endbfchar', dotAll: true);
  final hexPairPattern = RegExp(r'<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>');
  for (final section in bfCharPattern.allMatches(cmapSource)) {
    for (final pair in hexPairPattern.allMatches(section.group(1) ?? '')) {
      addBfChar(pair.group(1)!, pair.group(2)!);
    }
  }

  final bfRangePattern = RegExp(r'beginbfrange(.*?)endbfrange', dotAll: true);
  final rangeTriplePattern = RegExp(
    r'<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>',
  );
  for (final section in bfRangePattern.allMatches(cmapSource)) {
    for (final triple in rangeTriplePattern.allMatches(section.group(1) ?? '')) {
      final lo = int.tryParse(triple.group(1)!, radix: 16);
      final hi = int.tryParse(triple.group(2)!, radix: 16);
      final dstStart = int.tryParse(triple.group(3)!, radix: 16);
      if (lo == null || hi == null || dstStart == null) continue;
      for (var code = lo; code <= hi && code - lo < 65536; code++) {
        map[code] = String.fromCharCode(dstStart + (code - lo));
      }
    }
  }

  return map;
}

String _hexToUtf16String(String hex) {
  final codeUnits = <int>[];
  for (var i = 0; i + 4 <= hex.length; i += 4) {
    codeUnits.add(int.parse(hex.substring(i, i + 4), radix: 16));
  }
  return String.fromCharCodes(codeUnits);
}

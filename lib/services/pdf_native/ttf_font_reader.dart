import 'dart:typed_data';

/// Minimal read-only TrueType/OpenType parser: just enough to embed a
/// *whole, unsubsetted* font file into a PDF as a fallback for characters
/// missing from a document's own (embedded, subsetted) font. We don't
/// need glyf/loca/CFF outline parsing at all — the entire original file
/// is embedded verbatim — only `cmap` (Unicode -> glyph ID) and
/// `hmtx`/`hhea` (glyph advance widths) so the wrapping PDF CIDFont
/// dictionary can be built correctly.
class TtfFontInfo {
  const TtfFontInfo({
    required this.bytes,
    required this.isOpenTypeCff,
    required this.unitsPerEm,
    required this.numGlyphs,
    required this.unicodeToGid,
    required this.gidAdvanceWidth,
    required this.defaultAdvanceWidth,
  });

  /// The complete, untouched original font file bytes.
  final Uint8List bytes;

  /// True for 'OTTO' (CFF-flavored OpenType, needs FontFile3), false for
  /// classic TrueType/glyf-flavored ('true'/0x00010000, needs FontFile2).
  final bool isOpenTypeCff;

  final int unitsPerEm;
  final int numGlyphs;
  final Map<int, int> unicodeToGid;
  final Map<int, int> gidAdvanceWidth;
  final int defaultAdvanceWidth;
}

class TtfParseException implements Exception {
  TtfParseException(this.message);
  final String message;
  @override
  String toString() => 'TtfParseException: $message';
}

class _ByteReader {
  _ByteReader(this.bytes);
  final Uint8List bytes;
  late final ByteData data = bytes.buffer.asByteData(bytes.offsetInBytes, bytes.length);

  int u8(int offset) => data.getUint8(offset);
  int u16(int offset) => data.getUint16(offset, Endian.big);
  int i16(int offset) => data.getInt16(offset, Endian.big);
  int u32(int offset) => data.getUint32(offset, Endian.big);
}

TtfFontInfo parseTtf(Uint8List bytes) {
  final reader = _ByteReader(bytes);
  if (bytes.length < 12) throw TtfParseException('File too small');

  final sfntVersion = reader.u32(0);
  final isOpenTypeCff = sfntVersion == 0x4F54544F; // 'OTTO'
  final isTrueType = sfntVersion == 0x00010000 || sfntVersion == 0x74727565; // 'true'
  if (!isOpenTypeCff && !isTrueType) {
    throw TtfParseException('Not a TrueType/OpenType font (unsupported sfnt version)');
  }

  final numTables = reader.u16(4);
  final tables = <String, (int offset, int length)>{};
  for (var i = 0; i < numTables; i++) {
    final entryOffset = 12 + i * 16;
    if (entryOffset + 16 > bytes.length) break;
    final tag = String.fromCharCodes(bytes.sublist(entryOffset, entryOffset + 4));
    final offset = reader.u32(entryOffset + 8);
    final length = reader.u32(entryOffset + 12);
    tables[tag] = (offset, length);
  }

  final head = tables['head'];
  final unitsPerEm = head != null ? reader.u16(head.$1 + 18) : 1000;

  final maxp = tables['maxp'];
  final numGlyphs = maxp != null ? reader.u16(maxp.$1 + 4) : 0;

  final cmap = tables['cmap'];
  final unicodeToGid = cmap != null
      ? _parseCmap(reader, cmap.$1)
      : <int, int>{};

  final (gidAdvanceWidth, defaultAdvanceWidth) = _parseHmtx(
    reader,
    tables['hhea'],
    tables['hmtx'],
    numGlyphs,
  );

  return TtfFontInfo(
    bytes: bytes,
    isOpenTypeCff: isOpenTypeCff,
    unitsPerEm: unitsPerEm == 0 ? 1000 : unitsPerEm,
    numGlyphs: numGlyphs,
    unicodeToGid: unicodeToGid,
    gidAdvanceWidth: gidAdvanceWidth,
    defaultAdvanceWidth: defaultAdvanceWidth,
  );
}

Map<int, int> _parseCmap(_ByteReader reader, int cmapOffset) {
  final numSubtables = reader.u16(cmapOffset + 2);
  int? bestSubtableOffset;
  var bestScore = -1;

  for (var i = 0; i < numSubtables; i++) {
    final entryOffset = cmapOffset + 4 + i * 8;
    final platformId = reader.u16(entryOffset);
    final encodingId = reader.u16(entryOffset + 2);
    final subtableOffset = cmapOffset + reader.u32(entryOffset + 4);

    // Prefer Windows/Unicode BMP (3,1), then any Unicode platform (0,*),
    // then Windows full-repertoire (3,10).
    final score = switch ((platformId, encodingId)) {
      (3, 1) => 3,
      (0, _) => 2,
      (3, 10) => 1,
      _ => 0,
    };
    if (score > bestScore) {
      bestScore = score;
      bestSubtableOffset = subtableOffset;
    }
  }
  if (bestSubtableOffset == null) return {};

  final format = reader.u16(bestSubtableOffset);
  return switch (format) {
    4 => _parseCmapFormat4(reader, bestSubtableOffset),
    12 => _parseCmapFormat12(reader, bestSubtableOffset),
    _ => {},
  };
}

Map<int, int> _parseCmapFormat4(_ByteReader reader, int tableOffset) {
  final result = <int, int>{};
  final segCountX2 = reader.u16(tableOffset + 6);
  final segCount = segCountX2 ~/ 2;
  final endCodesOffset = tableOffset + 14;
  final startCodesOffset = endCodesOffset + segCountX2 + 2;
  final idDeltaOffset = startCodesOffset + segCountX2;
  final idRangeOffsetOffset = idDeltaOffset + segCountX2;

  for (var seg = 0; seg < segCount; seg++) {
    final endCode = reader.u16(endCodesOffset + seg * 2);
    final startCode = reader.u16(startCodesOffset + seg * 2);
    final idDelta = reader.i16(idDeltaOffset + seg * 2);
    final idRangeOffset = reader.u16(idRangeOffsetOffset + seg * 2);
    if (startCode == 0xFFFF && endCode == 0xFFFF) continue;

    for (var code = startCode; code <= endCode && code != 0xFFFF; code++) {
      int gid;
      if (idRangeOffset == 0) {
        gid = (code + idDelta) & 0xFFFF;
      } else {
        final glyphIndexAddress =
            idRangeOffsetOffset + seg * 2 + idRangeOffset + 2 * (code - startCode);
        if (glyphIndexAddress + 2 > reader.bytes.length) continue;
        gid = reader.u16(glyphIndexAddress);
        if (gid != 0) gid = (gid + idDelta) & 0xFFFF;
      }
      if (gid != 0) result[code] = gid;
    }
  }
  return result;
}

Map<int, int> _parseCmapFormat12(_ByteReader reader, int tableOffset) {
  final result = <int, int>{};
  final numGroups = reader.u32(tableOffset + 12);
  for (var g = 0; g < numGroups; g++) {
    final groupOffset = tableOffset + 16 + g * 12;
    if (groupOffset + 12 > reader.bytes.length) break;
    final startCharCode = reader.u32(groupOffset);
    final endCharCode = reader.u32(groupOffset + 4);
    final startGlyphId = reader.u32(groupOffset + 8);
    // Guard against pathological ranges bloating the map.
    final count = endCharCode - startCharCode + 1;
    if (count <= 0 || count > 100000) continue;
    for (var c = startCharCode; c <= endCharCode; c++) {
      result[c] = startGlyphId + (c - startCharCode);
    }
  }
  return result;
}

(Map<int, int>, int) _parseHmtx(
  _ByteReader reader,
  (int, int)? hhea,
  (int, int)? hmtx,
  int numGlyphs,
) {
  if (hhea == null || hmtx == null) return ({}, 500);
  final numOfLongHorMetrics = reader.u16(hhea.$1 + 34);
  final widths = <int, int>{};
  var lastWidth = 500;
  for (var gid = 0; gid < numOfLongHorMetrics && gid < numGlyphs; gid++) {
    final entryOffset = hmtx.$1 + gid * 4;
    if (entryOffset + 2 > reader.bytes.length) break;
    lastWidth = reader.u16(entryOffset);
    widths[gid] = lastWidth;
  }
  for (var gid = numOfLongHorMetrics; gid < numGlyphs; gid++) {
    widths[gid] = lastWidth;
  }
  return (widths, lastWidth);
}

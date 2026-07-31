import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/ttf_font_reader.dart';

void main() {
  late final bytes = File('assets/fonts/NanumGothic-Regular.ttf').readAsBytesSync();

  test('parses the bundled Korean fallback font', () {
    final ttf = parseTtf(bytes);
    expect(ttf.isOpenTypeCff, isFalse, reason: 'glyf-flavored TrueType, needs FontFile2');
    expect(ttf.unitsPerEm, greaterThan(0));
    expect(ttf.numGlyphs, greaterThan(1000));
  });

  test('cmap covers common Latin and Hangul syllable characters', () {
    final ttf = parseTtf(bytes);
    expect(ttf.unicodeToGid[0x41], isNotNull, reason: "'A' should be present");
    expect(ttf.unicodeToGid[0xAC00], isNotNull, reason: "'가' should be present");
    expect(ttf.unicodeToGid[0xB2E4], isNotNull, reason: "'다' should be present");
    // Not every conceivable code point is expected to exist — e.g. a
    // Private Use Area code point picked arbitrarily.
    expect(ttf.unicodeToGid[0xE000], isNull);
  });

  test('advance widths are populated for glyphs referenced by cmap', () {
    final ttf = parseTtf(bytes);
    final gid = ttf.unicodeToGid[0xAC00]!;
    expect(ttf.gidAdvanceWidth[gid], isNotNull);
    expect(ttf.gidAdvanceWidth[gid], greaterThan(0));
  });
}

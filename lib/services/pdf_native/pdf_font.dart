import 'dart:typed_data';

import 'pdf_document.dart';
import 'pdf_encodings.dart';
import 'pdf_objects.dart';

/// Resolved view of a page's `/Font` resource: enough to turn the raw
/// bytes of a `Tj`/`TJ` operator into displayable text (and, for simple
/// fonts only, back again) plus approximate glyph widths for drawing a
/// covering rectangle when redacting the original run.
class PdfFontInfo {
  const PdfFontInfo({
    required this.isCid,
    required this.decode,
    required this.encode,
    required this.widthOf,
    required this.unitsPerEm,
  });

  final bool isCid;

  /// Decodes raw operator bytes to displayable Unicode text.
  final String Function(Uint8List bytes) decode;

  /// Encodes [text] back into bytes valid for this exact font resource.
  /// Returns null when this can't be done losslessly (always the case for
  /// CID/Type0 fonts in this implementation — see class docs) — callers
  /// must then fall back to a different edit strategy (e.g. the OCR
  /// overlay path) rather than write corrupt operator bytes.
  final Uint8List? Function(String text) encode;

  /// Approximate glyph width (in the font's own unitsPerEm, typically
  /// 1000) for a single decoded character, used only to size a covering
  /// rectangle — not exact typesetting.
  final double Function(String char) widthOf;

  final double unitsPerEm;

  double measureWidth(String text) {
    var total = 0.0;
    for (final rune in text.runes) {
      total += widthOf(String.fromCharCode(rune));
    }
    return total;
  }
}

PdfFontInfo resolveFont(PdfDocument doc, PdfDictionaryObj fontDict) {
  final subtype = (doc.resolve(fontDict['Subtype']) as PdfName?)?.value;
  if (subtype == 'Type0') {
    return _resolveType0Font(doc, fontDict);
  }
  return _resolveSimpleFont(doc, fontDict);
}

PdfFontInfo _resolveSimpleFont(PdfDocument doc, PdfDictionaryObj fontDict) {
  final firstChar =
      (doc.resolve(fontDict['FirstChar']) as PdfNumber?)?.intValue ?? 0;
  final widthsArray = doc.resolve(fontDict['Widths']);
  final widths = widthsArray is PdfArrayObj
      ? widthsArray.items
          .map((item) => (doc.resolve(item) as PdfNumber?)?.doubleValue ?? 0)
          .toList()
      : const <double>[];
  final descriptor = doc.resolve(fontDict['FontDescriptor']);
  final missingWidth = descriptor is PdfDictionaryObj
      ? (doc.resolve(descriptor['MissingWidth']) as PdfNumber?)?.doubleValue ??
            500
      : 500.0;

  double widthOfCode(int code) {
    final idx = code - firstChar;
    if (idx >= 0 && idx < widths.length) return widths[idx];
    return missingWidth;
  }

  return PdfFontInfo(
    isCid: false,
    decode: decodeSimpleBytes,
    encode: encodeSimpleBytes,
    widthOf: (char) {
      if (char.isEmpty) return missingWidth;
      return widthOfCode(char.codeUnitAt(0));
    },
    unitsPerEm: 1000,
  );
}

PdfFontInfo _resolveType0Font(PdfDocument doc, PdfDictionaryObj fontDict) {
  final descendantsObj = doc.resolve(fontDict['DescendantFonts']);
  final descendant =
      descendantsObj is PdfArrayObj && descendantsObj.items.isNotEmpty
      ? doc.resolve(descendantsObj.items.first)
      : null;
  final descendantDict =
      descendant is PdfDictionaryObj ? descendant : const PdfDictionaryObj({});

  final defaultWidth =
      (doc.resolve(descendantDict['DW']) as PdfNumber?)?.doubleValue ?? 1000;
  final widthMap = _parseCidWidths(doc, doc.resolve(descendantDict['W']));

  Map<int, String>? toUnicode;
  final toUnicodeObj = doc.resolve(fontDict['ToUnicode']);
  if (toUnicodeObj is PdfStreamObj) {
    final decoded = doc.decodeStream(toUnicodeObj);
    toUnicode = parseToUnicodeCMap(String.fromCharCodes(decoded));
  }

  String decode(Uint8List bytes) {
    if (toUnicode == null) {
      // No ToUnicode CMap: we can't reliably map CIDs to characters
      // (that requires parsing the embedded font's own cmap table, out
      // of scope here). Surface a placeholder so callers can detect this
      // run is unreadable and fall back to the OCR overlay path.
      return '�' * (bytes.length ~/ 2);
    }
    final buffer = StringBuffer();
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final code = (bytes[i] << 8) | bytes[i + 1];
      buffer.write(toUnicode[code] ?? '�');
    }
    return buffer.toString();
  }

  return PdfFontInfo(
    isCid: true,
    decode: decode,
    // Re-encoding arbitrary new text into this font's CID space requires
    // the embedded font's Unicode->glyph cmap, which this reader doesn't
    // parse — always unsupported, by design (see PdfFontInfo.encode docs).
    encode: (_) => null,
    widthOf: (char) {
      if (char.isEmpty) return defaultWidth;
      return widthMap[char.codeUnitAt(0)] ?? defaultWidth;
    },
    unitsPerEm: 1000,
  );
}

/// Parses the CIDFont `/W` array. Two forms are supported:
/// `c [w1 w2 ...]` (per-CID widths starting at `c`) and
/// `cFirst cLast w` (a uniform width across a CID range). Keyed here by
/// decoded Unicode code point rather than CID since callers only ever
/// look widths up by character — an approximation that's fine for sizing
/// a covering rectangle.
Map<int, double> _parseCidWidths(PdfDocument doc, PdfObject? wObj) {
  final result = <int, double>{};
  if (wObj is! PdfArrayObj) return result;
  final items = wObj.items;
  var i = 0;
  while (i < items.length) {
    final first = doc.resolve(items[i]);
    if (first is! PdfNumber || i + 1 >= items.length) break;
    final second = doc.resolve(items[i + 1]);
    if (second is PdfArrayObj) {
      final startCid = first.intValue;
      for (var j = 0; j < second.items.length; j++) {
        final w = doc.resolve(second.items[j]);
        if (w is PdfNumber) result[startCid + j] = w.doubleValue;
      }
      i += 2;
    } else if (second is PdfNumber && i + 2 < items.length) {
      final w = doc.resolve(items[i + 2]);
      if (w is PdfNumber) {
        for (var cid = first.intValue; cid <= second.intValue; cid++) {
          result[cid] = w.doubleValue;
        }
      }
      i += 3;
    } else {
      break;
    }
  }
  return result;
}

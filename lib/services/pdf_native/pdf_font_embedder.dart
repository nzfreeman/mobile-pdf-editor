import 'dart:io';
import 'dart:typed_data';

import 'pdf_document.dart';
import 'pdf_incremental_writer.dart';
import 'pdf_objects.dart';
import 'ttf_font_reader.dart';

/// `/BaseFont` name stamped on every font this app embeds as a fallback,
/// so a later edit on the same page can recognize and reuse it instead
/// of embedding the (multi-megabyte) font file again.
const String kFallbackFontMarker = 'MobilePdfEditorEmbeddedKR';

/// A font embedded (or already present) in the target PDF that the app
/// can draw arbitrary characters with — used when the document's own
/// font can't represent a replacement character (see
/// PdfFontInfo.encode docs for why that happens).
class EmbeddedCidFont {
  const EmbeddedCidFont({
    required this.fontRef,
    required this.resourceName,
    required this.ttf,
  });

  final PdfRef fontRef;
  final String resourceName;
  final TtfFontInfo ttf;

  /// Encodes [text] as 2-byte GID codes (Identity-H, CIDToGIDMap
  /// Identity — GID is used directly as the CID). Returns null if any
  /// character isn't in this font's cmap at all (true fallback failure —
  /// at that point the OCR overlay is the only remaining option).
  Uint8List? encode(String text) {
    final gids = <int>[];
    for (final rune in text.runes) {
      final gid = ttf.unicodeToGid[rune];
      if (gid == null) return null;
      gids.add(gid);
    }
    final bytes = Uint8List(gids.length * 2);
    for (var i = 0; i < gids.length; i++) {
      bytes[i * 2] = (gids[i] >> 8) & 0xFF;
      bytes[i * 2 + 1] = gids[i] & 0xFF;
    }
    return bytes;
  }

  /// Approximate width in 1000-unit em space, matching the convention
  /// used by [PdfFontInfo.unitsPerEm] elsewhere in this package. Widths
  /// aren't embedded per-glyph in the PDF (see [buildEmbeddedFontWrites]
  /// docs) — this reads directly from the parsed font instead, for
  /// sizing the covering rectangle client-side.
  double widthOf(String char) {
    if (char.isEmpty) return _normalizedWidth(ttf.defaultAdvanceWidth);
    final gid = ttf.unicodeToGid[char.runes.first];
    final widthFontUnits = gid != null
        ? (ttf.gidAdvanceWidth[gid] ?? ttf.defaultAdvanceWidth)
        : ttf.defaultAdvanceWidth;
    return _normalizedWidth(widthFontUnits);
  }

  double _normalizedWidth(int fontUnits) => fontUnits * 1000 / ttf.unitsPerEm;

  double measureWidth(String text) {
    var total = 0.0;
    for (final rune in text.runes) {
      total += widthOf(String.fromCharCode(rune));
    }
    return total;
  }
}

/// Looks for a font this app previously embedded (identified by
/// [kFallbackFontMarker]) among [page]'s own font resources, so repeated
/// edits on the same page don't keep re-embedding the multi-megabyte
/// font file. [ttf] must be the same font this app always embeds
/// (bundled as an asset) — its cmap/metrics are reused directly rather
/// than re-parsing the embedded copy.
EmbeddedCidFont? findExistingEmbeddedFont(
  PdfDocument doc,
  PdfDictionaryObj page,
  TtfFontInfo ttf,
) {
  final resources = doc.inheritedAttribute(page, 'Resources');
  if (resources is! PdfDictionaryObj) return null;
  final fontDict = doc.resolve(resources['Font']);
  if (fontDict is! PdfDictionaryObj) return null;

  for (final entry in fontDict.entries.entries) {
    final fontObj = doc.resolve(entry.value);
    if (fontObj is! PdfDictionaryObj) continue;
    final descendants = doc.resolve(fontObj['DescendantFonts']);
    final descendant = descendants is PdfArrayObj && descendants.items.isNotEmpty
        ? doc.resolve(descendants.items.first)
        : null;
    if (descendant is! PdfDictionaryObj) continue;
    final descriptor = doc.resolve(descendant['FontDescriptor']);
    final fontName = descriptor is PdfDictionaryObj
        ? (doc.resolve(descriptor['FontName']) as PdfName?)?.value
        : null;
    if (fontName != kFallbackFontMarker) continue;

    final ref = entry.value is PdfRef ? entry.value as PdfRef : doc.refOf(fontObj);
    if (ref == null) continue;
    return EmbeddedCidFont(fontRef: ref, resourceName: entry.key, ttf: ttf);
  }
  return null;
}

/// Builds the PDF object graph (FontFile2 + FontDescriptor + CIDFontType2
/// + Type0) needed to embed [ttf] as a new, independently-usable font
/// resource, and a [PdfObjectWrite] updating [page] itself to register it
/// under [resourceName] in its `/Resources /Font` dictionary.
///
/// Deliberately does not embed a per-glyph `/W` widths array: doing so
/// for a full CJK font means thousands of entries for a feature that
/// only ever needs approximate positioning (the replacement text sits
/// inside a hand-drawn covering rectangle anyway, same as everywhere
/// else in this codebase's OCR-overlay path) — every glyph uses the
/// font's own default advance width (`/DW`) instead, which is accurate
/// for the very common case of monospaced-per-syllable Hangul fonts like
/// the bundled one.
({EmbeddedCidFont font, List<PdfObjectWrite> writes}) buildEmbeddedFontWrites({
  required PdfDocument doc,
  required PdfDictionaryObj page,
  required TtfFontInfo ttf,
  required String resourceName,
}) {
  final startObjNum = doc.allocateNewObjectNumbers(5);
  final fontFileRef = PdfRef(startObjNum, 0);
  final toUnicodeRef = PdfRef(startObjNum + 1, 0);
  final descriptorRef = PdfRef(startObjNum + 2, 0);
  final cidFontRef = PdfRef(startObjNum + 3, 0);
  final type0Ref = PdfRef(startObjNum + 4, 0);

  final compressed = Uint8List.fromList(zlib.encode(ttf.bytes));
  final fontFileDict = <String, PdfObject>{
    'Length': PdfNumber(compressed.length),
    'Filter': const PdfName('FlateDecode'),
    'Length1': PdfNumber(ttf.bytes.length),
  };
  final fontFileBody = BytesBuilder()
    ..add(encodeDict(fontFileDict).codeUnits)
    ..add('\nstream\n'.codeUnits)
    ..add(compressed)
    ..add('\nendstream'.codeUnits);

  // Without this, our own reader (and any other text-extraction tool)
  // can't decode text drawn with this font later — GID-based rendering
  // works fine without it, but re-editing that text or copy/search would
  // silently break. We control the GID<->Unicode mapping directly (it's
  // just the inverse of the cmap we already parsed), so this costs
  // nothing but a bit of file size.
  final toUnicodeSource = buildToUnicodeCMapSource(ttf.unicodeToGid);
  final toUnicodeCompressed = Uint8List.fromList(
    zlib.encode(toUnicodeSource.codeUnits),
  );
  final toUnicodeDict = <String, PdfObject>{
    'Length': PdfNumber(toUnicodeCompressed.length),
    'Filter': const PdfName('FlateDecode'),
  };
  final toUnicodeBody = BytesBuilder()
    ..add(encodeDict(toUnicodeDict).codeUnits)
    ..add('\nstream\n'.codeUnits)
    ..add(toUnicodeCompressed)
    ..add('\nendstream'.codeUnits);

  final ascent = (ttf.unitsPerEm * 0.9).round();
  final descent = -(ttf.unitsPerEm * 0.25).round();
  final defaultWidth = ttf.unicodeToGid[0xAC00] != null
      ? ttf.gidAdvanceWidth[ttf.unicodeToGid[0xAC00]] ?? ttf.defaultAdvanceWidth
      : ttf.defaultAdvanceWidth;
  final descriptorDict = <String, PdfObject>{
    'Type': const PdfName('FontDescriptor'),
    'FontName': const PdfName(kFallbackFontMarker),
    'Flags': const PdfNumber(32),
    'FontBBox': PdfArrayObj([
      const PdfNumber(0),
      PdfNumber(descent),
      PdfNumber(ttf.unitsPerEm),
      PdfNumber(ascent),
    ]),
    'ItalicAngle': const PdfNumber(0),
    'Ascent': PdfNumber(ascent),
    'Descent': PdfNumber(descent),
    'CapHeight': PdfNumber(ascent),
    'StemV': const PdfNumber(80),
    'FontFile2': fontFileRef,
  };

  final cidFontDict = <String, PdfObject>{
    'Type': const PdfName('Font'),
    'Subtype': const PdfName('CIDFontType2'),
    'BaseFont': const PdfName(kFallbackFontMarker),
    'CIDSystemInfo': PdfDictionaryObj({
      'Registry': PdfLiteralString(Uint8List.fromList('Adobe'.codeUnits)),
      'Ordering': PdfLiteralString(Uint8List.fromList('Identity'.codeUnits)),
      'Supplement': const PdfNumber(0),
    }),
    'FontDescriptor': descriptorRef,
    'DW': PdfNumber(defaultWidth * 1000 / ttf.unitsPerEm),
    'CIDToGIDMap': const PdfName('Identity'),
  };

  final type0Dict = <String, PdfObject>{
    'Type': const PdfName('Font'),
    'Subtype': const PdfName('Type0'),
    'BaseFont': const PdfName(kFallbackFontMarker),
    'Encoding': const PdfName('Identity-H'),
    'DescendantFonts': PdfArrayObj([cidFontRef]),
    'ToUnicode': toUnicodeRef,
  };

  final writes = [
    PdfObjectWrite(
      objectNumber: fontFileRef.objectNumber,
      generation: 0,
      body: fontFileBody.toBytes(),
    ),
    PdfObjectWrite(
      objectNumber: toUnicodeRef.objectNumber,
      generation: 0,
      body: toUnicodeBody.toBytes(),
    ),
    PdfObjectWrite(
      objectNumber: descriptorRef.objectNumber,
      generation: 0,
      body: Uint8List.fromList(encodeDict(descriptorDict).codeUnits),
    ),
    PdfObjectWrite(
      objectNumber: cidFontRef.objectNumber,
      generation: 0,
      body: Uint8List.fromList(encodeDict(cidFontDict).codeUnits),
    ),
    PdfObjectWrite(
      objectNumber: type0Ref.objectNumber,
      generation: 0,
      body: Uint8List.fromList(encodeDict(type0Dict).codeUnits),
    ),
    buildPageResourceFontWrite(
      doc: doc,
      page: page,
      resourceName: resourceName,
      fontRef: type0Ref,
    ),
  ];

  return (
    font: EmbeddedCidFont(fontRef: type0Ref, resourceName: resourceName, ttf: ttf),
    writes: writes,
  );
}

/// Builds a new revision of [page] itself with `/Resources /Font
/// /{resourceName}` added pointing at [fontRef]. Always targets the Page
/// object directly (rather than trying to figure out whether Resources
/// or Font were separately-indirect objects in the original file) since
/// a Page is always its own directly-addressable object — see the Kids
/// array that references it.
PdfObjectWrite buildPageResourceFontWrite({
  required PdfDocument doc,
  required PdfDictionaryObj page,
  required String resourceName,
  required PdfRef fontRef,
}) {
  final pageRef = doc.refOf(page);
  if (pageRef == null) {
    throw PdfNativeEditException(
      "Couldn't determine the page's own object reference",
    );
  }

  final resourcesResolved = doc.resolve(page['Resources']);
  final resourcesEntries = Map<String, PdfObject>.from(
    resourcesResolved is PdfDictionaryObj ? resourcesResolved.entries : {},
  );
  final fontDictResolved = doc.resolve(resourcesEntries['Font']);
  final fontEntries = Map<String, PdfObject>.from(
    fontDictResolved is PdfDictionaryObj ? fontDictResolved.entries : {},
  );
  fontEntries[resourceName] = fontRef;
  resourcesEntries['Font'] = PdfDictionaryObj(fontEntries);

  final newPageEntries = Map<String, PdfObject>.from(page.entries);
  newPageEntries['Resources'] = PdfDictionaryObj(resourcesEntries);

  return PdfObjectWrite(
    objectNumber: pageRef.objectNumber,
    generation: pageRef.generation,
    body: Uint8List.fromList(encodeDict(newPageEntries).codeUnits),
  );
}

/// Builds a ToUnicode CMap (bfchar blocks, batched per the conventional
/// 100-entries-per-block limit) mapping every glyph ID in [unicodeToGid]
/// back to its Unicode code point. Only handles the BMP (single UTF-16
/// code unit) — every character this app's fallback font actually needs
/// to cover (Hangul + Latin) falls within that range.
String buildToUnicodeCMapSource(Map<int, int> unicodeToGid) {
  final gidToUnicode = <int, int>{};
  for (final entry in unicodeToGid.entries) {
    gidToUnicode.putIfAbsent(entry.value, () => entry.key);
  }
  final sortedGids = gidToUnicode.keys.toList()..sort();

  final buffer = StringBuffer()
    ..writeln('/CIDInit /ProcSet findresource begin')
    ..writeln('12 dict begin')
    ..writeln('begincmap')
    ..writeln('1 begincodespacerange')
    ..writeln('<0000> <FFFF>')
    ..writeln('endcodespacerange');

  const batchSize = 100;
  for (var i = 0; i < sortedGids.length; i += batchSize) {
    final batch = sortedGids.skip(i).take(batchSize).where((gid) => gidToUnicode[gid]! <= 0xFFFF).toList();
    if (batch.isEmpty) continue;
    buffer.writeln('${batch.length} beginbfchar');
    for (final gid in batch) {
      final unicode = gidToUnicode[gid]!;
      buffer.writeln(
        '<${gid.toRadixString(16).padLeft(4, '0')}> '
        '<${unicode.toRadixString(16).padLeft(4, '0')}>',
      );
    }
    buffer.writeln('endbfchar');
  }
  buffer
    ..writeln('endcmap')
    ..writeln('CMapName currentdict /CMapName get def')
    ..writeln('end')
    ..write('end');
  return buffer.toString();
}

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'pdf_content_stream.dart';
import 'pdf_document.dart';
import 'pdf_font_embedder.dart';
import 'pdf_incremental_writer.dart';
import 'pdf_native_edit_builder.dart';
import 'pdf_objects.dart';
import 'ttf_font_reader.dart';

class PdfNativePage {
  const PdfNativePage({required this.pageIndex, required this.runs});
  final int pageIndex;
  final List<PdfTextRun> runs;
}

/// Public entry point for the "read/edit real PDF text objects" feature:
/// wires the low-level parser, content-stream walker, font resolver, font
/// embedder, and incremental writer together.
///
/// Scope, by design (see individual file docs for details): this only
/// understands FlateDecode-compressed, unencrypted PDFs with classic or
/// xref-stream cross-reference tables. Text using simple (WinAnsi-ish
/// single-byte) fonts can always be read and edited in place, preserving
/// the original font resource. Text using Type0/CID composite fonts
/// (which is how most Korean/CJK text is encoded) can be *read* whenever
/// the font has an embedded ToUnicode CMap, and can be *edited* by
/// reusing characters already embedded elsewhere in the document under
/// that font. When the replacement text needs a character that exists in
/// neither the original font nor anywhere else in the document, this
/// falls back to embedding a bundled Korean-capable font (see
/// pdf_font_embedder.dart) so the edit still preserves *a* real,
/// selectable PDF font — only when even that bundled font lacks the
/// character (a genuine rarity) does [PdfRunNotEditableException]
/// surface, and callers should fall back to the OCR-overlay edit flow.
class PdfNativeTextService {
  PdfNativeTextService._();

  static const _fallbackFontAsset = 'assets/fonts/NanumGothic-Regular.ttf';
  static TtfFontInfo? _cachedFallbackTtf;

  static Future<TtfFontInfo> _loadFallbackTtf() async {
    final cached = _cachedFallbackTtf;
    if (cached != null) return cached;
    final data = await rootBundle.load(_fallbackFontAsset);
    final ttf = parseTtf(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    _cachedFallbackTtf = ttf;
    return ttf;
  }

  static Future<List<PdfNativePage>> extractRuns(File file) async {
    final bytes = await file.readAsBytes();
    final doc = PdfDocument.parse(bytes);
    final pages = doc.pages;
    return [
      for (var i = 0; i < pages.length; i++)
        PdfNativePage(pageIndex: i, runs: extractTextRuns(doc, pages[i])),
    ];
  }

  static Future<({File file, bool usedFallbackFont})> replaceRunText({
    required File file,
    required int pageIndex,
    required PdfTextRun run,
    required String newText,
  }) async {
    final bytes = await file.readAsBytes();
    final doc = PdfDocument.parse(bytes);
    final pages = doc.pages;
    if (pageIndex < 0 || pageIndex >= pages.length) {
      throw PdfNativeEditException('Page index $pageIndex out of range');
    }
    final page = pages[pageIndex];

    final writes = <PdfObjectWrite>[];
    final Uint8List replacementBytes;
    final usedFallbackFont = run.font.encode(newText) == null;
    if (!usedFallbackFont) {
      replacementBytes = buildReplacementOperatorBytes(run, newText);
    } else {
      final ttf = await _loadFallbackTtf();
      var embedded = findExistingEmbeddedFont(doc, page, ttf);
      if (embedded == null) {
        final built = buildEmbeddedFontWrites(
          doc: doc,
          page: page,
          ttf: ttf,
          resourceName: _uniqueFontResourceName(doc, page),
        );
        embedded = built.font;
        writes.addAll(built.writes);
      }
      replacementBytes = buildReplacementOperatorBytes(
        run,
        newText,
        fallbackFont: embedded,
      );
    }

    writes.add(
      buildEditedStreamWrite(doc, run.contentStreamRef, [
        PdfEdit(
          streamRef: run.contentStreamRef,
          start: run.byteStartInStream,
          end: run.byteEndInStream,
          replacement: replacementBytes,
        ),
      ]),
    );

    final newBytes = applyObjectWrites(doc, bytes, writes);

    final directory = await getApplicationDocumentsDirectory();
    final output = File(
      '${directory.path}/native_edit_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await output.writeAsBytes(newBytes, flush: true);
    return (file: output, usedFallbackFont: usedFallbackFont);
  }

  static String _uniqueFontResourceName(PdfDocument doc, PdfDictionaryObj page) {
    final resources = doc.inheritedAttribute(page, 'Resources');
    final fontDict = resources is PdfDictionaryObj
        ? doc.resolve(resources['Font'])
        : null;
    final existing = fontDict is PdfDictionaryObj
        ? fontDict.entries.keys.toSet()
        : const <String>{};
    var i = 0;
    while (existing.contains('FBK$i')) {
      i++;
    }
    return 'FBK$i';
  }
}

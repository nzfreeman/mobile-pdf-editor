import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_content_stream.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_font_embedder.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_incremental_writer.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_native_edit_builder.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_objects.dart';
import 'package:mobile_pdf_editor/services/pdf_native/ttf_font_reader.dart';

/// Same minimal CID-font fixture as pdf_native_cid_font_test.dart: a
/// document whose only embedded font knows '가' and '나', but not '다' —
/// the case the font embedder exists to handle.
Uint8List _buildCidFontPdf() {
  const toUnicodeCMap = '''
/CIDInit /ProcSet findresource begin
1 begincodespacerange
<0000> <FFFF>
endcodespacerange
2 beginbfchar
<0001> <AC00>
<0002> <B098>
endbfchar
endcmap
''';

  final objects = <String, List<int>>{};
  objects['1'] = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'.codeUnits;
  objects['2'] = '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n'.codeUnits;
  objects['3'] =
      '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] '
              '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n'
          .codeUnits;
  objects['4'] =
      '4 0 obj\n<< /Type /Font /Subtype /Type0 /BaseFont /TestCid '
              '/Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 7 0 R >>\nendobj\n'
          .codeUnits;
  objects['6'] =
      '6 0 obj\n<< /Type /Font /Subtype /CIDFontType2 /BaseFont /TestCid '
              '/DW 1000 >>\nendobj\n'
          .codeUnits;

  const contentStream = 'BT\n/F1 24 Tf\n15 30 Td\n<0001> Tj\nET';
  final contentBytes = contentStream.codeUnits;
  objects['5'] = [
    ...'5 0 obj\n<< /Length ${contentBytes.length} >>\nstream\n'.codeUnits,
    ...contentBytes,
    ...'\nendstream\nendobj\n'.codeUnits,
  ];

  final cmapBytes = toUnicodeCMap.codeUnits;
  objects['7'] = [
    ...'7 0 obj\n<< /Length ${cmapBytes.length} >>\nstream\n'.codeUnits,
    ...cmapBytes,
    ...'\nendstream\nendobj\n'.codeUnits,
  ];

  final out = BytesBuilder();
  out.add('%PDF-1.4\n'.codeUnits);
  final offsets = <int, int>{};
  for (final key in ['1', '2', '3', '4', '5', '6', '7']) {
    offsets[int.parse(key)] = out.length;
    out.add(objects[key]!);
  }

  final xrefOffset = out.length;
  final xref = StringBuffer()
    ..writeln('xref')
    ..writeln('0 8')
    ..writeln('0000000000 65535 f ');
  for (var i = 1; i <= 7; i++) {
    xref.writeln('${offsets[i]!.toString().padLeft(10, '0')} 00000 n ');
  }
  xref
    ..writeln('trailer')
    ..writeln('<< /Size 8 /Root 1 0 R >>')
    ..writeln('startxref')
    ..writeln(xrefOffset)
    ..write('%%EOF');
  out.add(xref.toString().codeUnits);

  return out.toBytes();
}

void main() {
  late final ttf = parseTtf(File('assets/fonts/NanumGothic-Regular.ttf').readAsBytesSync());

  test('embedding a fallback font lets an out-of-vocabulary character round-trip', () {
    final pdfBytes = _buildCidFontPdf();
    final doc = PdfDocument.parse(pdfBytes);
    final page = doc.pages.single;
    final run = extractTextRuns(doc, page).single;
    expect(run.text, '가');
    expect(run.font.encode('다'), isNull, reason: "the doc's own font doesn't know '다'");

    final built = buildEmbeddedFontWrites(
      doc: doc,
      page: page,
      ttf: ttf,
      resourceName: 'FBK0',
    );
    expect(built.font.encode('다'), isNotNull);

    final replacementOp = buildReplacementOperatorBytes(
      run,
      '다',
      fallbackFont: built.font,
    );
    final writes = [
      ...built.writes,
      buildEditedStreamWrite(doc, run.contentStreamRef, [
        PdfEdit(
          streamRef: run.contentStreamRef,
          start: run.byteStartInStream,
          end: run.byteEndInStream,
          replacement: replacementOp,
        ),
      ]),
    ];
    final edited = applyObjectWrites(doc, pdfBytes, writes);

    expect(
      edited.sublist(0, pdfBytes.length),
      equals(pdfBytes),
      reason: 'incremental update must not modify original bytes',
    );

    final reparsed = PdfDocument.parse(edited);
    final reparsedPage = reparsed.pages.single;
    final newRuns = extractTextRuns(reparsed, reparsedPage);
    expect(newRuns, hasLength(1));
    expect(newRuns.single.text, '다');
    expect(newRuns.single.fontResourceName, 'FBK0');

    // The embedded font must now be discoverable for reuse by a later
    // edit on the same page, without needing to re-embed it.
    final foundAgain = findExistingEmbeddedFont(reparsed, reparsedPage, ttf);
    expect(foundAgain, isNotNull);
    expect(foundAgain!.resourceName, 'FBK0');
  });

  test('an existing embedded fallback font is reused, not re-embedded', () {
    final pdfBytes = _buildCidFontPdf();
    final doc = PdfDocument.parse(pdfBytes);
    final page = doc.pages.single;

    final first = buildEmbeddedFontWrites(
      doc: doc,
      page: page,
      ttf: ttf,
      resourceName: 'FBK0',
    );
    final afterFirstEmbed = applyObjectWrites(doc, pdfBytes, first.writes);
    final docAfterFirst = PdfDocument.parse(afterFirstEmbed);
    final pageAfterFirst = docAfterFirst.pages.single;

    final found = findExistingEmbeddedFont(docAfterFirst, pageAfterFirst, ttf);
    expect(found, isNotNull);
    expect(found!.resourceName, 'FBK0');
    expect(found.encode('바'), isNotNull);
  });

  test(
    'the embedded font carries real per-glyph widths (a /W array), not just a '
    'uniform default — otherwise every character renders with identical, '
    'monospaced-looking spacing regardless of its actual glyph shape',
    () {
      final pdfBytes = _buildCidFontPdf();
      final doc = PdfDocument.parse(pdfBytes);
      final page = doc.pages.single;

      final built = buildEmbeddedFontWrites(
        doc: doc,
        page: page,
        ttf: ttf,
        resourceName: 'FBK0',
      );
      final edited = applyObjectWrites(doc, pdfBytes, built.writes);
      final reparsed = PdfDocument.parse(edited);

      final type0Dict = reparsed.getObject(built.font.fontRef);
      final descendants = reparsed.resolve(
        (type0Dict as PdfDictionaryObj)['DescendantFonts'],
      );
      final cidFontDict = reparsed.resolve(
        (descendants as PdfArrayObj).items.first,
      );
      final wArray = reparsed.resolve((cidFontDict as PdfDictionaryObj)['W']);
      expect(wArray, isA<PdfArrayObj>(), reason: 'a /W array must be present');
      expect((wArray as PdfArrayObj).items, isNotEmpty);

      // A narrow glyph (e.g. Latin 'i') and a wide one (a full-width
      // Hangul syllable) must not report the same width — that's
      // exactly what "monospaced-looking" means here.
      final narrowWidth = built.font.widthOf('i');
      final wideWidth = built.font.widthOf('가');
      expect(narrowWidth, isNot(closeTo(wideWidth, 1)));
    },
  );
}

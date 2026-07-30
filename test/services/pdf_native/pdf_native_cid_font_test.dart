import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_content_stream.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_incremental_writer.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_native_edit_builder.dart';

/// Builds a minimal Type0/CID font PDF with Identity-H encoding and a
/// ToUnicode CMap, mirroring how real-world Korean text PDFs represent
/// Hangul (which can't fit in a single-byte simple-font encoding). This
/// exercises the read-only CID path specifically — the one Korean
/// documents will actually hit.
Uint8List _buildCidFontPdf({bool includeToUnicode = true}) {
  // Two 2-byte CIDs (0x0001, 0x0002), mapped via ToUnicode to '가' (AC00)
  // and '나' (B098) — non-sequential code points, so bfchar (not bfrange)
  // is the correct way to express this mapping.
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
  final toUnicodeEntry = includeToUnicode ? ' /ToUnicode 7 0 R' : '';
  objects['4'] =
      '4 0 obj\n<< /Type /Font /Subtype /Type0 /BaseFont /TestCid '
              '/Encoding /Identity-H /DescendantFonts [6 0 R]$toUnicodeEntry >>\nendobj\n'
          .codeUnits;
  objects['6'] =
      '6 0 obj\n<< /Type /Font /Subtype /CIDFontType2 /BaseFont /TestCid '
              '/DW 1000 >>\nendobj\n'
          .codeUnits;

  const contentStream = 'BT\n/F1 24 Tf\n15 30 Td\n<00010002> Tj\nET';
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
  test('CID/Type0 font with ToUnicode CMap decodes via bfchar', () {
    final pdfBytes = _buildCidFontPdf();
    final doc = PdfDocument.parse(pdfBytes);
    final runs = extractTextRuns(doc, doc.pages.single);

    expect(runs, hasLength(1));
    final run = runs.single;
    expect(run.font.isCid, isTrue);
    expect(run.text, '가나');
  });

  test('CID font without a ToUnicode CMap decodes to placeholders, not garbage', () {
    // Same fixture but without a /ToUnicode reference, simulating a
    // document where we genuinely cannot know the text.
    final pdfBytes = _buildCidFontPdf(includeToUnicode: false);
    final doc = PdfDocument.parse(pdfBytes);
    final runs = extractTextRuns(doc, doc.pages.single);
    expect(runs, hasLength(1));
    expect(runs.single.text, contains('�'));
    expect(runs.single.isEditable, isFalse);
  });

  test(
    'CID text can be edited by reusing CIDs already embedded for other characters',
    () {
      final pdfBytes = _buildCidFontPdf();
      final doc = PdfDocument.parse(pdfBytes);
      final run = extractTextRuns(doc, doc.pages.single).single;

      // '나가' reuses only characters ('가','나') already embedded in this
      // font (as CIDs 1 and 2) — just reordered — so this must succeed
      // without needing to touch the embedded font program at all.
      expect(run.isEditable, isTrue);

      final replacementOp = buildReplacementOperatorBytes(run, '나가');
      final edited = applyIncrementalEdits(doc, pdfBytes, [
        PdfEdit(
          streamRef: run.contentStreamRef,
          start: run.byteStartInStream,
          end: run.byteEndInStream,
          replacement: replacementOp,
        ),
      ]);

      final reparsed = PdfDocument.parse(edited);
      final newRuns = extractTextRuns(reparsed, reparsed.pages.single);
      expect(newRuns, hasLength(1));
      expect(newRuns.single.text, '나가');
    },
  );

  test(
    'CID text cannot be edited to include a character never embedded in the font',
    () {
      final pdfBytes = _buildCidFontPdf();
      final doc = PdfDocument.parse(pdfBytes);
      final run = extractTextRuns(doc, doc.pages.single).single;

      // '다' was never embedded anywhere in this font's ToUnicode map —
      // there is no CID we can reuse for it without parsing the embedded
      // font program, which this reader doesn't do.
      expect(
        () => buildReplacementOperatorBytes(run, '다'),
        throwsA(isA<PdfRunNotEditableException>()),
      );
    },
  );
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_content_stream.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_incremental_writer.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_native_edit_builder.dart';

Uint8List _buildPdfWithLetterSpacing({required double charSpacing}) {
  final objects = <String, List<int>>{};
  objects['1'] = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'.codeUnits;
  objects['2'] = '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n'.codeUnits;
  objects['3'] =
      '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] '
              '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n'
          .codeUnits;
  objects['4'] =
      '4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
              '/Encoding /WinAnsiEncoding >>\nendobj\n'
          .codeUnits;

  final contentStream =
      'BT\n/F1 12 Tf\n$charSpacing Tc\n10 20 Td\n(Header) Tj\nET';
  final contentBytes = contentStream.codeUnits;
  objects['5'] = [
    ...'5 0 obj\n<< /Length ${contentBytes.length} >>\nstream\n'.codeUnits,
    ...contentBytes,
    ...'\nendstream\nendobj\n'.codeUnits,
  ];

  final out = BytesBuilder();
  out.add('%PDF-1.4\n'.codeUnits);
  final offsets = <int, int>{};
  for (final key in ['1', '2', '3', '4', '5']) {
    offsets[int.parse(key)] = out.length;
    out.add(objects[key]!);
  }
  final xrefOffset = out.length;
  final xref = StringBuffer()
    ..writeln('xref')
    ..writeln('0 6')
    ..writeln('0000000000 65535 f ');
  for (var i = 1; i <= 5; i++) {
    xref.writeln('${offsets[i]!.toString().padLeft(10, '0')} 00000 n ');
  }
  xref
    ..writeln('trailer')
    ..writeln('<< /Size 6 /Root 1 0 R >>')
    ..writeln('startxref')
    ..writeln(xrefOffset)
    ..write('%%EOF');
  out.add(xref.toString().codeUnits);
  return out.toBytes();
}

void main() {
  test('extractTextRuns picks up non-default Tc/Tw/Tz from the content stream', () {
    final doc = PdfDocument.parse(_buildPdfWithLetterSpacing(charSpacing: 2.5));
    final run = extractTextRuns(doc, doc.pages.single).single;
    expect(run.charSpacing, closeTo(2.5, 0.01));
    expect(run.wordSpacing, closeTo(0, 0.01));
    expect(run.horizScalePercent, closeTo(100, 0.01));
  });

  test(
    'a replacement drawn with the run\'s original letter-spacing round-trips '
    "that spacing, rather than silently reverting to the default",
    () {
      final pdfBytes = _buildPdfWithLetterSpacing(charSpacing: 3.0);
      final doc = PdfDocument.parse(pdfBytes);
      final run = extractTextRuns(doc, doc.pages.single).single;
      expect(run.charSpacing, closeTo(3.0, 0.01));

      final replacementOp = buildReplacementOperatorBytes(run, 'New Label');
      final edited = applyIncrementalEdits(doc, pdfBytes, [
        PdfEdit(
          streamRef: run.contentStreamRef,
          start: run.byteStartInStream,
          end: run.byteEndInStream,
          replacement: replacementOp,
        ),
      ]);

      final reparsed = PdfDocument.parse(edited);
      final newRun = extractTextRuns(reparsed, reparsed.pages.single).single;
      expect(newRun.text, 'New Label');
      expect(
        newRun.charSpacing,
        closeTo(3.0, 0.01),
        reason: 'the replacement must keep the original letter-spacing, not reset to 0',
      );
    },
  );
}

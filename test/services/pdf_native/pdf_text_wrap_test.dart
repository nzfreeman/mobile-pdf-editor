import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_content_stream.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_incremental_writer.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_native_edit_builder.dart';

Uint8List _buildSimpleFontPdf({required String originalText}) {
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

  final contentStream = 'BT\n/F1 12 Tf\n10 20 Td\n($originalText) Tj\nET';
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
  test(
    'a replacement much longer than the original wraps onto multiple lines '
    'instead of extending far past a single-line width',
    () {
      final pdfBytes = _buildSimpleFontPdf(originalText: 'WO123');
      final doc = PdfDocument.parse(pdfBytes);
      final run = extractTextRuns(doc, doc.pages.single).single;

      const longText =
          'Web Order WO10290876 tests and tested and inspection and picked '
          'and test again and test and this needs to wrap';
      final replacementOp = buildReplacementOperatorBytes(run, longText);
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

      expect(
        newRuns.length,
        greaterThan(1),
        reason: 'long replacement text should produce multiple Tj lines, not one huge line',
      );
      expect(newRuns.map((r) => r.text).join(' '), contains('wrap'));

      // Every wrapped line should have roughly bounded width — i.e. no
      // single run's text is anywhere near the full original sentence,
      // which is what "running off the page" would look like.
      for (final run in newRuns) {
        expect(run.text.length, lessThan(longText.length));
      }
    },
  );

  test(
    'a replacement only slightly wider than the original is condensed to '
    'fit the original footprint instead of overflowing into whatever the '
    'page draws next on that line (e.g. an adjacent table cell)',
    () {
      final pdfBytes = _buildSimpleFontPdf(originalText: '345,678');
      final doc = PdfDocument.parse(pdfBytes);
      final run = extractTextRuns(doc, doc.pages.single).single;

      final replacementOp = buildReplacementOperatorBytes(run, '345,7689');
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
      expect(
        newRuns,
        hasLength(1),
        reason: 'a one-character-longer replacement should not wrap to a second line',
      );
      expect(newRuns.single.text, '345,7689');
      expect(
        newRuns.single.horizScalePercent,
        lessThan(100),
        reason: 'the extra character should be fit via horizontal compression',
      );
    },
  );

  test('a replacement no longer than the original stays on one line', () {
    final pdfBytes = _buildSimpleFontPdf(originalText: 'Hello');
    final doc = PdfDocument.parse(pdfBytes);
    final run = extractTextRuns(doc, doc.pages.single).single;

    final replacementOp = buildReplacementOperatorBytes(run, 'Bye');
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
    expect(newRuns.single.text, 'Bye');
  });
}

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_content_stream.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_incremental_writer.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_native_edit_builder.dart';

/// Hand-builds a minimal, syntactically valid single-page PDF with one
/// `Tj` text run, computing exact xref offsets as it goes — there's no
/// other reliable way to get a real PDF byte layout for these tests
/// without depending on an external PDF library (which would then be
/// what's actually under test, not our own parser).
Uint8List _buildMinimalPdf({required String contentStream, bool compress = false}) {
  final objects = <String, List<int>>{};
  final contentBytes = contentStream.codeUnits;
  final Uint8List streamBytes;
  final String extraDictEntries;
  if (compress) {
    streamBytes = Uint8List.fromList(zlib.encode(contentBytes));
    extraDictEntries = ' /Filter /FlateDecode';
  } else {
    streamBytes = Uint8List.fromList(contentBytes);
    extraDictEntries = '';
  }

  objects['1'] = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'.codeUnits;
  objects['2'] = '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n'.codeUnits;
  objects['3'] =
      '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] '
              '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n'
          .codeUnits;
  objects['4'] =
      '4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
              '/Encoding /WinAnsiEncoding >>\nendobj\n'
          .codeUnits;

  final streamObjHead = '5 0 obj\n<< /Length ${streamBytes.length}$extraDictEntries >>\nstream\n';
  final streamObjBytes = <int>[
    ...streamObjHead.codeUnits,
    ...streamBytes,
    ...'\nendstream\nendobj\n'.codeUnits,
  ];

  final out = BytesBuilder();
  out.add('%PDF-1.4\n'.codeUnits);
  final offsets = <int, int>{};
  for (final key in ['1', '2', '3', '4']) {
    offsets[int.parse(key)] = out.length;
    out.add(objects[key]!);
  }
  offsets[5] = out.length;
  out.add(streamObjBytes);

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
  for (final compress in [false, true]) {
    group(compress ? 'FlateDecode content stream' : 'raw content stream', () {
      late Uint8List pdfBytes;

      setUp(() {
        pdfBytes = _buildMinimalPdf(
          contentStream: 'BT\n/F1 12 Tf\n10 20 Td\n(Hello) Tj\nET',
          compress: compress,
        );
      });

      test('parses pages and resolves the Root/Pages tree', () {
        final doc = PdfDocument.parse(pdfBytes);
        expect(doc.pages, hasLength(1));
      });

      test('extracts the single text run with correct text/position/font', () {
        final doc = PdfDocument.parse(pdfBytes);
        final runs = extractTextRuns(doc, doc.pages.single);
        expect(runs, hasLength(1));
        final run = runs.single;
        expect(run.text, 'Hello');
        expect(run.originX, closeTo(10, 0.01));
        expect(run.originY, closeTo(20, 0.01));
        expect(run.fontSize, closeTo(12, 0.01));
        expect(run.fontResourceName, 'F1');
        expect(run.font.isCid, isFalse);
        expect(run.isEditable, isTrue);
      });

      test('round-trips an edit: replace text, re-parse, see the new text', () {
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

        // The incremental update must be purely additive: every original
        // byte is untouched.
        expect(
          edited.sublist(0, pdfBytes.length),
          equals(pdfBytes),
          reason: 'incremental update must not modify original bytes',
        );
        expect(edited.length, greaterThan(pdfBytes.length));

        final reparsed = PdfDocument.parse(edited);
        final newRuns = extractTextRuns(reparsed, reparsed.pages.single);
        expect(newRuns, hasLength(1));
        expect(newRuns.single.text, 'Bye');
      });

      test('unedited runs on other pages/streams are unaffected by an edit', () {
        // Build a second run in the same content stream to confirm a
        // targeted edit doesn't disturb sibling operators.
        final twoRunBytes = _buildMinimalPdf(
          contentStream:
              'BT\n/F1 12 Tf\n10 20 Td\n(Hello) Tj\n0 -20 Td\n(World) Tj\nET',
          compress: compress,
        );
        final doc = PdfDocument.parse(twoRunBytes);
        final runs = extractTextRuns(doc, doc.pages.single);
        expect(runs, hasLength(2));
        expect(runs[0].text, 'Hello');
        expect(runs[1].text, 'World');

        final replacementOp = buildReplacementOperatorBytes(runs[0], 'Bye');
        final edited = applyIncrementalEdits(doc, twoRunBytes, [
          PdfEdit(
            streamRef: runs[0].contentStreamRef,
            start: runs[0].byteStartInStream,
            end: runs[0].byteEndInStream,
            replacement: replacementOp,
          ),
        ]);

        final reparsed = PdfDocument.parse(edited);
        final newRuns = extractTextRuns(reparsed, reparsed.pages.single);
        expect(newRuns, hasLength(2));
        expect(newRuns[0].text, 'Bye');
        expect(newRuns[1].text, 'World', reason: 'sibling run must be untouched');
      });
    });
  }
}

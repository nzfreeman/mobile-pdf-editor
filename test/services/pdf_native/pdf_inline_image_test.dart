import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_content_stream.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';

/// Builds a one-page PDF whose content stream draws an inline image
/// (BI...ID...EI, common for small icons/watermarks/scan artifacts
/// rather than a full XObject) with [rawImageBytes] as its raw data,
/// followed by a real text-showing operator — the case that actually
/// exercises whether inline image data corrupts parsing of everything
/// after it.
Uint8List _buildPdfWithInlineImage(Uint8List rawImageBytes) {
  final objects = <String, List<int>>{};
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

  final content = BytesBuilder()
    ..add('q\nBI /W 2 /H 2 /BPC 8 /CS /G ID '.codeUnits)
    ..add(rawImageBytes)
    ..add(' EI\nQ\nBT\n/F1 12 Tf\n10 20 Td\n(Hello) Tj\nET'.codeUnits);
  final contentBytes = content.toBytes();

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
    'text after an inline image with an unmatched literal-string delimiter '
    'in its raw data still parses correctly',
    () {
      // A raw '(' with no matching ')' before EI would, without special
      // inline-image handling, make the generic tokenizer's literal-
      // string reader consume straight through the real EI/Q/BT/Tj
      // operators looking for a closing paren that never comes.
      final bytes = _buildPdfWithInlineImage(Uint8List.fromList([0x28, 1, 2, 3]));
      final doc = PdfDocument.parse(bytes);
      final runs = extractTextRuns(doc, doc.pages.single);

      expect(runs, hasLength(1));
      expect(runs.single.text, 'Hello');
      expect(runs.single.originX, closeTo(10, 0.01));
      expect(runs.single.originY, closeTo(20, 0.01));
    },
  );

  test('text after an inline image with ordinary binary data parses correctly', () {
    final bytes = _buildPdfWithInlineImage(
      Uint8List.fromList([0, 128, 255, 64]),
    );
    final doc = PdfDocument.parse(bytes);
    final runs = extractTextRuns(doc, doc.pages.single);

    expect(runs, hasLength(1));
    expect(runs.single.text, 'Hello');
  });
}

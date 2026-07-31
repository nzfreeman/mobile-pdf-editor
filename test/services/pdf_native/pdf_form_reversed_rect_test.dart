import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_form_fields.dart';

/// Builds a one-field form PDF with [rect] as the field's literal `/Rect`
/// array (in whatever corner order the caller supplies) — the PDF spec
/// permits either corner first; a reader must normalize.
Uint8List _buildFormPdfWithRect(List<int> rect) {
  final objects = <String, List<int>>{};
  objects['1'] = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 4 0 R >>\nendobj\n'.codeUnits;
  objects['2'] = '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n'.codeUnits;
  objects['3'] =
      '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] '
              '/Resources << >> /Contents 5 0 R /Annots [7 0 R] >>\nendobj\n'
          .codeUnits;

  const contentStream = 'q Q';
  final contentBytes = contentStream.codeUnits;
  objects['5'] = [
    ...'5 0 obj\n<< /Length ${contentBytes.length} >>\nstream\n'.codeUnits,
    ...contentBytes,
    ...'\nendstream\nendobj\n'.codeUnits,
  ];

  objects['4'] = '4 0 obj\n<< /Fields [7 0 R] /DA (/Helv 12 Tf 0 g) >>\nendobj\n'.codeUnits;

  final rectStr = rect.join(' ');
  objects['7'] =
      '7 0 obj\n<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) '
              '/Rect [$rectStr] /V () /P 3 0 R >>\nendobj\n'
          .codeUnits;

  final out = BytesBuilder();
  out.add('%PDF-1.4\n'.codeUnits);
  final offsets = <int, int>{};
  for (final key in ['1', '2', '3', '4', '5', '7']) {
    offsets[int.parse(key)] = out.length;
    out.add(objects[key]!);
  }
  final xrefOffset = out.length;
  final xref = StringBuffer()
    ..writeln('xref')
    ..writeln('0 8')
    ..writeln('0000000000 65535 f ');
  for (var i = 1; i <= 7; i++) {
    final offset = offsets[i];
    xref.writeln(
      '${(offset ?? 0).toString().padLeft(10, '0')} 00000 ${offset == null ? 'f' : 'n'} ',
    );
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
  test(
    'a /Rect with corners given backwards normalizes to the same position as '
    'the same rect given in the conventional order',
    () {
      final conventional = extractFormFields(
        PdfDocument.parse(_buildFormPdfWithRect([50, 500, 350, 530])),
      ).single;
      final reversed = extractFormFields(
        PdfDocument.parse(_buildFormPdfWithRect([350, 530, 50, 500])),
      ).single;

      expect(reversed.normX, closeTo(conventional.normX, 0.0001));
      expect(reversed.normY, closeTo(conventional.normY, 0.0001));
      expect(reversed.normWidth, closeTo(conventional.normWidth, 0.0001));
      expect(reversed.normHeight, closeTo(conventional.normHeight, 0.0001));
      expect(reversed.normWidth, greaterThan(0));
      expect(reversed.normHeight, greaterThan(0));
    },
  );
}

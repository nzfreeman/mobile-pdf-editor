import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';

/// A trivially minimal PDF whose trailer declares /Encrypt — the object
/// structure is otherwise parseable, but string/stream *content* would
/// still be ciphertext, which this reader has no way to decrypt.
Uint8List _buildEncryptedPdf() {
  final objects = <String, List<int>>{};
  objects['1'] = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'.codeUnits;
  objects['2'] = '2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n'.codeUnits;
  objects['3'] =
      '3 0 obj\n<< /Filter /Standard /V 1 /R 2 /O <00> /U <00> /P -4 >>\nendobj\n'
          .codeUnits;

  final out = BytesBuilder();
  out.add('%PDF-1.4\n'.codeUnits);
  final offsets = <int, int>{};
  for (final key in ['1', '2', '3']) {
    offsets[int.parse(key)] = out.length;
    out.add(objects[key]!);
  }
  final xrefOffset = out.length;
  final xref = StringBuffer()
    ..writeln('xref')
    ..writeln('0 4')
    ..writeln('0000000000 65535 f ');
  for (var i = 1; i <= 3; i++) {
    xref.writeln('${offsets[i]!.toString().padLeft(10, '0')} 00000 n ');
  }
  xref
    ..writeln('trailer')
    ..writeln('<< /Size 4 /Root 1 0 R /Encrypt 3 0 R >>')
    ..writeln('startxref')
    ..writeln(xrefOffset)
    ..write('%%EOF');
  out.add(xref.toString().codeUnits);
  return out.toBytes();
}

void main() {
  test(
    'parse() rejects encrypted PDFs loudly rather than silently returning '
    'a document whose string/stream content is still ciphertext',
    () {
      expect(
        () => PdfDocument.parse(_buildEncryptedPdf()),
        throwsA(isA<PdfParseException>()),
      );
    },
  );
}

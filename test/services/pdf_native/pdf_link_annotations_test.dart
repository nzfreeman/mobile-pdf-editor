import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_link_annotations.dart';

Uint8List _buildPdfWithLinks() {
  final objects = <String, List<int>>{};
  objects['1'] = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'.codeUnits;
  objects['2'] =
      '2 0 obj\n<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>\nendobj\n'.codeUnits;
  objects['3'] =
      '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 400] '
              '/Annots [4 0 R 5 0 R] /Contents 7 0 R >>\nendobj\n'
          .codeUnits;
  objects['4'] =
      '4 0 obj\n<< /Type /Annot /Subtype /Link /Rect [20 300 80 340] '
              '/A << /S /URI /URI (https://example.com) >> >>\nendobj\n'
          .codeUnits;
  objects['5'] =
      '5 0 obj\n<< /Type /Annot /Subtype /Link /Rect [20 20 80 60] '
              '/A << /S /GoTo /D [6 0 R /XYZ null null null] >> >>\nendobj\n'
          .codeUnits;
  objects['6'] =
      '6 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 400] '
              '/Contents 7 0 R >>\nendobj\n'
          .codeUnits;
  objects['7'] =
      '7 0 obj\n<< /Length 0 >>\nstream\n\nendstream\nendobj\n'.codeUnits;

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
  test('extracts a URI link and a GoTo page-jump link with normalized rects', () {
    final doc = PdfDocument.parse(_buildPdfWithLinks());
    final links = extractLinkAnnotations(doc);
    expect(links, hasLength(2));

    final uriLink = links.firstWhere((l) => l.uri != null);
    expect(uriLink.pageIndex, 0);
    expect(uriLink.uri, 'https://example.com');
    expect(uriLink.destPageIndex, isNull);
    // Rect [20 300 80 340] on a 200x400 MediaBox, flipped to top-left y-down.
    expect(uriLink.rectX, closeTo(20 / 200, 0.001));
    expect(uriLink.rectY, closeTo((400 - 340) / 400, 0.001));
    expect(uriLink.rectWidth, closeTo(60 / 200, 0.001));
    expect(uriLink.rectHeight, closeTo(40 / 400, 0.001));

    final gotoLink = links.firstWhere((l) => l.destPageIndex != null);
    expect(gotoLink.pageIndex, 0);
    expect(gotoLink.destPageIndex, 1);
    expect(gotoLink.uri, isNull);
  });

  test('returns an empty list when a page has no /Annots', () {
    final objects = <String, List<int>>{};
    objects['1'] = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'.codeUnits;
    objects['2'] = '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n'
        .codeUnits;
    objects['3'] =
        '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 400] >>\nendobj\n'
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
      ..writeln('<< /Size 4 /Root 1 0 R >>')
      ..writeln('startxref')
      ..writeln(xrefOffset)
      ..write('%%EOF');
    out.add(xref.toString().codeUnits);

    final doc = PdfDocument.parse(out.toBytes());
    expect(extractLinkAnnotations(doc), isEmpty);
  });
}

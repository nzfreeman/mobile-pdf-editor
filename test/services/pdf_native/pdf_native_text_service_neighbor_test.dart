import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_content_stream.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_native_text_service.dart';

/// Two separate text runs on the same line: an editable field on the
/// left, and fixed "table cell" content immediately to its right —
/// close enough that a naive replacement would overlap it.
Uint8List _buildTwoRunsOnSameLinePdf() {
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

  // "345,678" starts at x=10; "Total" (the neighboring cell) starts at
  // x=70, leaving a fairly tight gap for a longer replacement to fit in.
  const contentStream =
      'BT\n/F1 12 Tf\n10 20 Td\n(345,678) Tj\nET\n'
      'BT\n/F1 12 Tf\n70 20 Td\n(Total) Tj\nET';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    final tempDir = await Directory.systemTemp.createTemp('pdf_native_docs');
    addTearDown(() => tempDir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return tempDir.path;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
  });

  test(
    'editing a field fits the replacement before a neighboring run on the '
    'same line, rather than overlapping it',
    () async {
      final pdfBytes = _buildTwoRunsOnSameLinePdf();
      final doc = PdfDocument.parse(pdfBytes);
      final page = doc.pages.single;
      final runs = extractTextRuns(doc, page);
      final editableRun = runs.firstWhere((r) => r.text == '345,678');
      final neighbor = runs.firstWhere((r) => r.text == 'Total');

      final tempDir = Directory.systemTemp.createTempSync('neighbor_test');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final file = File('${tempDir.path}/sample.pdf')..writeAsBytesSync(pdfBytes);

      final result = await PdfNativeTextService.replaceRunText(
        file: file,
        pageIndex: 0,
        run: editableRun,
        newText: '345,76789',
      );

      final reparsed = PdfDocument.parse(await result.file.readAsBytes());
      final newRuns = extractTextRuns(reparsed, reparsed.pages.single);
      final editedRun = newRuns.firstWhere((r) => r.text == '345,76789');

      final rightEdge =
          editedRun.originX +
          editedRun.font.measureWidth(editedRun.text) /
              editedRun.font.unitsPerEm *
              editedRun.fontSize *
              (editedRun.horizScalePercent / 100);

      expect(
        rightEdge,
        lessThanOrEqualTo(neighbor.originX),
        reason: 'the compressed replacement should not overlap the neighboring "Total" run',
      );
    },
  );
}

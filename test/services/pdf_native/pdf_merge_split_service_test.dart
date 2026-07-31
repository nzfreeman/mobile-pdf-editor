import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_content_stream.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_merge_split_service.dart';

/// A minimal single-page PDF whose one text run says [text], with a
/// distinct object-numbering "namespace" per fixture (all fixtures start
/// numbering at 1, which is exactly the case the copier's renumbering
/// must handle correctly when combining multiple such files).
Uint8List _buildSinglePagePdf(String text) {
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

  final contentStream = 'BT\n/F1 12 Tf\n10 20 Td\n($text) Tj\nET';
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

/// A multi-page PDF (all pages sharing one font resource, each with its
/// own content stream) for testing split.
Uint8List _buildMultiPagePdf(List<String> pageTexts) {
  final objects = <String, List<int>>{};
  final pageObjNums = List.generate(pageTexts.length, (i) => 3 + i * 2);
  final contentObjNums = List.generate(pageTexts.length, (i) => 4 + i * 2);
  final fontObjNum = 3 + pageTexts.length * 2;

  objects['1'] = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'.codeUnits;
  final kids = pageObjNums.map((n) => '$n 0 R').join(' ');
  objects['2'] =
      '2 0 obj\n<< /Type /Pages /Kids [$kids] /Count ${pageTexts.length} >>\nendobj\n'
          .codeUnits;
  objects['$fontObjNum'] =
      '$fontObjNum 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
              '/Encoding /WinAnsiEncoding >>\nendobj\n'
          .codeUnits;

  for (var i = 0; i < pageTexts.length; i++) {
    final pageNum = pageObjNums[i];
    final contentNum = contentObjNums[i];
    objects['$pageNum'] =
        '$pageNum 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] '
                '/Resources << /Font << /F1 $fontObjNum 0 R >> >> /Contents $contentNum 0 R >>\nendobj\n'
            .codeUnits;
    final contentStream = 'BT\n/F1 12 Tf\n10 20 Td\n(${pageTexts[i]}) Tj\nET';
    final contentBytes = contentStream.codeUnits;
    objects['$contentNum'] = [
      ...'$contentNum 0 obj\n<< /Length ${contentBytes.length} >>\nstream\n'.codeUnits,
      ...contentBytes,
      ...'\nendstream\nendobj\n'.codeUnits,
    ];
  }

  final out = BytesBuilder();
  out.add('%PDF-1.4\n'.codeUnits);
  final offsets = <int, int>{};
  final allKeys = ['1', '2', ...pageObjNums.map((n) => '$n'), ...contentObjNums.map((n) => '$n'), '$fontObjNum'];
  final sortedKeys = allKeys.map(int.parse).toSet().toList()..sort();
  for (final key in sortedKeys) {
    offsets[key] = out.length;
    out.add(objects['$key']!);
  }

  final xrefOffset = out.length;
  final size = sortedKeys.last + 1;
  final xref = StringBuffer()
    ..writeln('xref')
    ..writeln('0 $size')
    ..writeln('0000000000 65535 f ');
  for (var i = 1; i < size; i++) {
    xref.writeln('${offsets[i]!.toString().padLeft(10, '0')} 00000 n ');
  }
  xref
    ..writeln('trailer')
    ..writeln('<< /Size $size /Root 1 0 R >>')
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
    final tempDir = await Directory.systemTemp.createTemp('merge_split_test');
    addTearDown(() => tempDir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') return tempDir.path;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
  });

  test(
    'merge combines pages from documents that each independently number objects '
    'starting at 1, and text stays real/extractable (not rasterized)',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('merge_inputs');
      addTearDown(() => tempDir.delete(recursive: true));
      final fileA = File('${tempDir.path}/a.pdf');
      final fileB = File('${tempDir.path}/b.pdf');
      await fileA.writeAsBytes(_buildSinglePagePdf('First'));
      await fileB.writeAsBytes(_buildSinglePagePdf('Second'));

      final merged = await PdfMergeSplitService.merge(
        files: [fileA, fileB],
        outputName: 'merged.pdf',
      );
      addTearDown(() => merged.delete());

      final doc = PdfDocument.parse(await merged.readAsBytes());
      expect(doc.pages, hasLength(2));
      expect(
        extractTextRuns(doc, doc.pages[0]).single.text,
        'First',
        reason: 'text must be a real, re-extractable run, not a raster image',
      );
      expect(extractTextRuns(doc, doc.pages[1]).single.text, 'Second');
    },
  );

  test('split produces one file per page group with the right pages/text', () async {
    final tempDir = await Directory.systemTemp.createTemp('split_input');
    addTearDown(() => tempDir.delete(recursive: true));
    final file = File('${tempDir.path}/multi.pdf');
    await file.writeAsBytes(_buildMultiPagePdf(['Page1', 'Page2', 'Page3']));

    final outputs = await PdfMergeSplitService.split(
      file: file,
      pageGroups: [
        [0, 1],
        [2],
      ],
      sourceName: 'multi.pdf',
    );
    addTearDown(() {
      for (final output in outputs) {
        output.delete();
      }
    });

    expect(outputs, hasLength(2));

    final firstDoc = PdfDocument.parse(await outputs[0].readAsBytes());
    expect(firstDoc.pages, hasLength(2));
    expect(extractTextRuns(firstDoc, firstDoc.pages[0]).single.text, 'Page1');
    expect(extractTextRuns(firstDoc, firstDoc.pages[1]).single.text, 'Page2');

    final secondDoc = PdfDocument.parse(await outputs[1].readAsBytes());
    expect(secondDoc.pages, hasLength(1));
    expect(extractTextRuns(secondDoc, secondDoc.pages[0]).single.text, 'Page3');
  });
}

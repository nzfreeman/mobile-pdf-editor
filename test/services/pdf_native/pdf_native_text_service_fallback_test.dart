import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_content_stream.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_native_text_service.dart';

Uint8List _buildCidFontPdf() {
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
  objects['4'] =
      '4 0 obj\n<< /Type /Font /Subtype /Type0 /BaseFont /TestCid '
              '/Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 7 0 R >>\nendobj\n'
          .codeUnits;
  objects['6'] =
      '6 0 obj\n<< /Type /Font /Subtype /CIDFontType2 /BaseFont /TestCid '
              '/DW 1000 >>\nendobj\n'
          .codeUnits;

  const contentStream = 'BT\n/F1 24 Tf\n15 30 Td\n<0001> Tj\nET';
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
    'replaceRunText transparently embeds a fallback font for out-of-vocabulary text, '
    'and reuses it (does not re-embed) on a second edit',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('pdf_native_test');
      addTearDown(() => tempDir.delete(recursive: true));
      final sourceFile = File('${tempDir.path}/source.pdf');
      await sourceFile.writeAsBytes(_buildCidFontPdf());

      final pages = await PdfNativeTextService.extractRuns(sourceFile);
      expect(pages, hasLength(1));
      final run = pages.single.runs.single;
      expect(run.text, '가');

      // '다' is nowhere in the document's own font — must go through the
      // fallback-embedding path.
      final firstResult = await PdfNativeTextService.replaceRunText(
        file: sourceFile,
        pageIndex: 0,
        run: run,
        newText: '다',
      );
      final firstEdit = firstResult.file;
      addTearDown(() => firstEdit.delete());
      expect(firstResult.usedFallbackFont, isTrue);

      final firstBytes = await firstEdit.readAsBytes();
      final firstDoc = PdfDocument.parse(firstBytes);
      final firstRuns = extractTextRuns(firstDoc, firstDoc.pages.single);
      expect(firstRuns, hasLength(1));
      expect(firstRuns.single.text, '다');

      // Edit again, on the already-edited file, with another character
      // absent from the *original* font — should reuse the already-
      // embedded fallback font rather than embedding a second copy
      // (checked indirectly via file size: a second full font embed
      // would add roughly as many bytes as the first). Because the
      // fallback font carries a full ToUnicode map (unlike the original
      // synthetic test font), this run's own font can represent '바'
      // directly — the ordinary CID-reuse path handles it without even
      // calling into the embedder again, which is a stronger result than
      // needing the embedder's own reuse-detection.
      final secondRun = firstRuns.single;
      final secondResult = await PdfNativeTextService.replaceRunText(
        file: firstEdit,
        pageIndex: 0,
        run: secondRun,
        newText: '바',
      );
      final secondEdit = secondResult.file;
      expect(secondResult.usedFallbackFont, isFalse);
      addTearDown(() => secondEdit.delete());

      final firstEditSize = await firstEdit.length();
      final secondEditSize = await secondEdit.length();
      final growthFromFirstEdit = firstEditSize; // original was tiny
      final growthFromSecondEdit = secondEditSize - firstEditSize;
      expect(
        growthFromSecondEdit,
        lessThan(growthFromFirstEdit ~/ 10),
        reason: 'second edit must not re-embed the ~multi-hundred-KB fallback font',
      );

      final secondDoc = PdfDocument.parse(await secondEdit.readAsBytes());
      final secondRuns = extractTextRuns(secondDoc, secondDoc.pages.single);
      expect(secondRuns, hasLength(1));
      expect(secondRuns.single.text, '바');
    },
  );
}

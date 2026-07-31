import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_merge_split_service.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_objects.dart';

/// A page that defines no /MediaBox of its own — it relies entirely on
/// the ancestor /Pages node's /MediaBox (legal and common: many
/// producers set MediaBox once at the tree level instead of repeating
/// it on every page).
Uint8List _buildInheritedMediaBoxPdf() {
  final objects = <String, List<int>>{};
  objects['1'] = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'.codeUnits;
  objects['2'] =
      '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400] >>\nendobj\n'
          .codeUnits;
  objects['3'] =
      '3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 5 0 R /Resources << >> >>\nendobj\n'
          .codeUnits;
  const contentStream = 'q Q';
  final contentBytes = contentStream.codeUnits;
  objects['5'] = [
    ...'5 0 obj\n<< /Length ${contentBytes.length} >>\nstream\n'.codeUnits,
    ...contentBytes,
    ...'\nendstream\nendobj\n'.codeUnits,
  ];

  final out = BytesBuilder();
  out.add('%PDF-1.4\n'.codeUnits);
  final offsets = <int, int>{};
  for (final key in ['1', '2', '3', '5']) {
    offsets[int.parse(key)] = out.length;
    out.add(objects[key]!);
  }
  final xrefOffset = out.length;
  final xref = StringBuffer()
    ..writeln('xref')
    ..writeln('0 6')
    ..writeln('0000000000 65535 f ');
  for (var i = 1; i <= 5; i++) {
    final offset = offsets[i];
    xref.writeln(
      '${(offset ?? 0).toString().padLeft(10, '0')} 00000 ${offset == null ? 'f' : 'n'} ',
    );
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
    final tempDir = await Directory.systemTemp.createTemp('object_copier_test');
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
    'merge inlines a MediaBox inherited from the ancestor Pages node, since '
    "the copy deliberately doesn't carry over the original /Parent chain",
    () async {
      final tempDir = await Directory.systemTemp.createTemp('inherited_input');
      addTearDown(() => tempDir.delete(recursive: true));
      final file = File('${tempDir.path}/a.pdf');
      await file.writeAsBytes(_buildInheritedMediaBoxPdf());

      final merged = await PdfMergeSplitService.merge(
        files: [file],
        outputName: 'out.pdf',
      );
      addTearDown(() => merged.delete());

      final doc = PdfDocument.parse(await merged.readAsBytes());
      final page = doc.pages.single;
      final mediaBox = doc.resolve(page['MediaBox']);
      expect(mediaBox, isA<PdfArrayObj>(), reason: 'MediaBox must not be lost');
      final values = (mediaBox as PdfArrayObj).items
          .map((o) => (doc.resolve(o) as PdfNumber).doubleValue)
          .toList();
      expect(values, [0, 0, 300, 400]);
    },
  );
}

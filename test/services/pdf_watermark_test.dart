import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mobile_pdf_editor/services/pdf_native/pdf_content_stream.dart';
import 'package:mobile_pdf_editor/services/pdf_native/pdf_document.dart';
import 'package:mobile_pdf_editor/services/pdf_service.dart';

RenderedPdfPage _blankPage({double width = 400, double height = 600}) {
  final image = img.Image(width: 200, height: 300);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  return RenderedPdfPage(
    bytes: Uint8List.fromList(img.encodePng(image)),
    width: width,
    height: height,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    final tempDir = await Directory.systemTemp.createTemp('watermark_test');
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

  test('text watermark (tiled) produces a valid multi-page PDF with the watermark text', () async {
    final output = await PdfService.addWatermarkToPages(
      pages: [_blankPage(), _blankPage()],
      sourceName: 'doc.pdf',
      text: 'CONFIDENTIAL',
      tile: true,
    );
    addTearDown(() => output.delete());

    final bytes = await output.readAsBytes();
    final doc = PdfDocument.parse(bytes);
    expect(doc.pages, hasLength(2));

    for (final page in doc.pages) {
      final runs = extractTextRuns(doc, page);
      expect(runs, isNotEmpty, reason: 'tiled watermark should draw several text runs');
      expect(runs.every((r) => r.text == 'CONFIDENTIAL'), isTrue);
    }
  });

  test('text watermark (centered, not tiled) draws exactly one run per page', () async {
    final output = await PdfService.addWatermarkToPages(
      pages: [_blankPage()],
      sourceName: 'doc.pdf',
      text: 'DRAFT',
      tile: false,
    );
    addTearDown(() => output.delete());

    final doc = PdfDocument.parse(await output.readAsBytes());
    final runs = extractTextRuns(doc, doc.pages.single);
    expect(runs, hasLength(1));
    expect(runs.single.text, 'DRAFT');
  });

  test('image watermark does not crash and produces a valid PDF', () async {
    final stampImage = img.Image(width: 40, height: 40);
    img.fill(stampImage, color: img.ColorRgb8(200, 0, 0));
    final stampBytes = Uint8List.fromList(img.encodePng(stampImage));

    final output = await PdfService.addWatermarkToPages(
      pages: [_blankPage()],
      sourceName: 'doc.pdf',
      imageBytes: stampBytes,
      tile: true,
    );
    addTearDown(() => output.delete());

    final doc = PdfDocument.parse(await output.readAsBytes());
    expect(doc.pages, hasLength(1));
  });
}

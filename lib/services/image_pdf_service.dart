import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class ImagePdfService {
  static Future<File> createPdf(List<File> images) async {
    if (images.isEmpty) {
      throw ArgumentError('이미지를 한 장 이상 선택해야 합니다.');
    }

    final document = pw.Document(compress: true);
    for (final imageFile in images) {
      final rawBytes = await imageFile.readAsBytes();
      // Re-encode through package:image so formats the pdf package's own
      // MemoryImage can't sniff directly (BMP, TIFF, WebP, ...) still
      // work — only the decoded pixels matter here, not the source
      // container format.
      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) {
        throw StateError('${imageFile.path} 이미지를 읽을 수 없습니다.');
      }
      final pngBytes = img.encodePng(decoded);
      final image = pw.MemoryImage(pngBytes);
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(18),
          build: (_) =>
              pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
        ),
      );
    }

    final directory = await getApplicationDocumentsDirectory();
    final output = File(
      '${directory.path}/images_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await output.writeAsBytes(await document.save(), flush: true);
    return output;
  }

  /// Lays out plain text as a paginated PDF (wrapping automatically via
  /// `pw.Paragraph`/`pw.MultiPage`), for the "텍스트 파일 → PDF" tool. Uses
  /// the bundled Korean font rather than the pdf package's built-in
  /// Helvetica, which has no Hangul glyphs and would render Korean text
  /// as blank boxes.
  static Future<File> createPdfFromText(String text, {String? title}) async {
    final fontData = await rootBundle.load(
      'assets/fonts/NanumGothic-Regular.ttf',
    );
    final font = pw.Font.ttf(fontData);

    final document = pw.Document(compress: true);
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        theme: pw.ThemeData.withFont(base: font, bold: font),
        build: (_) => [
          if (title != null && title.isNotEmpty) ...[
            pw.Text(
              title,
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 12),
          ],
          pw.Text(text, style: const pw.TextStyle(fontSize: 11)),
        ],
      ),
    );

    final directory = await getApplicationDocumentsDirectory();
    final output = File(
      '${directory.path}/text_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await output.writeAsBytes(await document.save(), flush: true);
    return output;
  }
}

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'docx_service.dart';

/// Loads the bundled Korean font once — the pdf package's built-in
/// Helvetica has no Hangul glyphs and renders Korean text as blank boxes.
Future<pw.Font> _loadKoreanFont() async {
  final data = await rootBundle.load('assets/fonts/NanumGothic-Regular.ttf');
  return pw.Font.ttf(data);
}

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
    final font = await _loadKoreanFont();

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

  /// Renders parsed docx content ([DocxService.parse]) with paragraph-level
  /// bold/italic/underline, headings, inline images, and simple tables —
  /// the "reasonable fidelity" tier between raw text and a full Word
  /// layout engine. See [DocxService] for what's deliberately not
  /// reproduced (custom fonts, precise spacing, nested tables, floats).
  static Future<File> createPdfFromDocxBlocks(
    List<DocxBlock> blocks, {
    String? title,
  }) async {
    final font = await _loadKoreanFont();
    final document = pw.Document(compress: true);

    pw.TextStyle styleFor(DocxTextSpan span, {int? headingLevel}) {
      final headingSize = switch (headingLevel) {
        0 => 22.0,
        1 => 19.0,
        2 => 16.0,
        3 => 14.0,
        _ => null,
      };
      return pw.TextStyle(
        fontSize: headingSize ?? 11,
        fontWeight: (span.bold || headingLevel != null)
            ? pw.FontWeight.bold
            : pw.FontWeight.normal,
        fontStyle: span.italic ? pw.FontStyle.italic : pw.FontStyle.normal,
        decoration: span.underline
            ? pw.TextDecoration.underline
            : pw.TextDecoration.none,
      );
    }

    final widgets = <pw.Widget>[
      if (title != null && title.isNotEmpty) ...[
        pw.Text(
          title,
          style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 14),
      ],
    ];

    for (final block in blocks) {
      switch (block) {
        case DocxParagraph():
          if (block.spans.isEmpty) {
            widgets.add(pw.SizedBox(height: 8));
            continue;
          }
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: pw.RichText(
                text: pw.TextSpan(
                  children: block.spans
                      .map(
                        (span) => pw.TextSpan(
                          text: span.text,
                          style: styleFor(
                            span,
                            headingLevel: block.headingLevel,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          );
        case DocxImage():
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 6),
              child: pw.ConstrainedBox(
                constraints: const pw.BoxConstraints(maxHeight: 260),
                child: pw.Image(
                  pw.MemoryImage(block.bytes),
                  fit: pw.BoxFit.contain,
                ),
              ),
            ),
          );
        case DocxTable():
          if (block.rows.isEmpty) continue;
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 8),
              child: pw.TableHelper.fromTextArray(
                headers: block.rows.first,
                data: block.rows.skip(1).toList(),
                cellStyle: const pw.TextStyle(fontSize: 9),
                headerStyle: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                ),
                border: pw.TableBorder.all(width: 0.5),
              ),
            ),
          );
      }
    }

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        theme: pw.ThemeData.withFont(base: font, bold: font),
        build: (_) => widgets,
      ),
    );

    final directory = await getApplicationDocumentsDirectory();
    final output = File(
      '${directory.path}/docx_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await output.writeAsBytes(await document.save(), flush: true);
    return output;
  }
}

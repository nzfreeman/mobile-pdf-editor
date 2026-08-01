import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' as pdf_core;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../models/editor_item.dart';

enum PdfCompressionLevel { low, medium, high }

class RenderedPdfPage {
  const RenderedPdfPage({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final double width;
  final double height;

  double get aspectRatio => width / height;
}

class PdfService {
  static Future<List<RenderedPdfPage>> renderAllPages(File file) async {
    final document = await pdfrx.PdfDocument.openFile(file.path);
    final result = <RenderedPdfPage>[];

    try {
      for (final page in document.pages) {
        final scale = math.min(2.0, 1800 / page.width);
        final targetWidth = math.max(1, (page.width * scale).round());
        final targetHeight = math.max(1, (page.height * scale).round());
        final rendered = await page.render(
          width: targetWidth,
          height: targetHeight,
          fullWidth: targetWidth.toDouble(),
          fullHeight: targetHeight.toDouble(),
          backgroundColor: 0xFFFFFFFF,
        );

        if (rendered == null) {
          throw StateError('${page.pageNumber} 페이지 렌더링 실패');
        }

        try {
          final image = await rendered.createImage();
          try {
            final byteData = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            if (byteData == null) {
              throw StateError('${page.pageNumber} 페이지 이미지 변환 실패');
            }
            result.add(
              RenderedPdfPage(
                bytes: byteData.buffer.asUint8List(),
                width: page.width,
                height: page.height,
              ),
            );
          } finally {
            image.dispose();
          }
        } finally {
          rendered.dispose();
        }
      }
    } finally {
      await document.dispose();
    }

    return result;
  }

  static Future<File> exportMultiPagePdf({
    required List<RenderedPdfPage> pages,
    required List<EditorItem> items,
    required String sourceName,
  }) async {
    // Text/memo/link items are drawn with a real font rather than the pdf
    // package's built-in Helvetica, which has no Hangul glyphs and would
    // render Korean labels as blank boxes.
    final fontData = await rootBundle.load(
      'assets/fonts/NanumGothic-Regular.ttf',
    );
    final font = pw.Font.ttf(fontData);
    final document = pw.Document(
      compress: true,
      theme: pw.ThemeData.withFont(base: font, bold: font),
    );

    for (var index = 0; index < pages.length; index++) {
      final page = pages[index];
      final pageItems = items.where((item) => item.pageIndex == index).toList();
      final pageFormat = pdf_core.PdfPageFormat(page.width, page.height);
      final background = pw.MemoryImage(page.bytes);

      document.addPage(
        pw.Page(
          pageFormat: pageFormat,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Stack(
            children: [
              pw.Positioned.fill(
                child: pw.Image(background, fit: pw.BoxFit.fill),
              ),
              ...pageItems.map(
                (item) => _buildPdfItem(item, page.width, page.height),
              ),
            ],
          ),
        ),
      );
    }

    final directory = await getApplicationDocumentsDirectory();
    final safeName = sourceName
        .replaceAll(RegExp(r'\.[Pp][Dd][Ff]$'), '')
        .replaceAll(RegExp(r'[^a-zA-Z0-9가-힣_-]'), '_');
    final output = File(
      '${directory.path}/${safeName}_edited_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await output.writeAsBytes(await document.save(), flush: true);
    return output;
  }

  /// Re-encodes every page as a quality/size-reduced JPEG and rebuilds the
  /// PDF, which shrinks output size considerably versus the lossless PNG
  /// pages produced by [renderAllPages].
  static Future<File> compressPdf({
    required File file,
    required String sourceName,
    PdfCompressionLevel level = PdfCompressionLevel.medium,
  }) async {
    final pages = await renderAllPages(file);
    final (quality, maxDimension) = switch (level) {
      PdfCompressionLevel.low => (35, 900),
      PdfCompressionLevel.medium => (55, 1280),
      PdfCompressionLevel.high => (75, 1800),
    };

    final compressed = <RenderedPdfPage>[];
    for (final page in pages) {
      final decoded = img.decodeImage(page.bytes);
      if (decoded == null) {
        compressed.add(page);
        continue;
      }
      final resized = decoded.width > maxDimension
          ? img.copyResize(decoded, width: maxDimension)
          : decoded;
      compressed.add(
        RenderedPdfPage(
          bytes: Uint8List.fromList(img.encodeJpg(resized, quality: quality)),
          width: page.width,
          height: page.height,
        ),
      );
    }
    return exportMultiPagePdf(
      pages: compressed,
      items: const [],
      sourceName: sourceName,
    );
  }

  /// Stamps a text or image watermark onto every page of [file]. Exactly
  /// one of [text]/[imageBytes] should be given.
  static Future<File> addWatermark({
    required File file,
    required String sourceName,
    String? text,
    Uint8List? imageBytes,
    double opacity = 0.3,
    double rotationDegrees = -45,
    bool tile = true,
    double fontSize = 40,
    int colorValue = 0xFF808080,
  }) async {
    final pages = await renderAllPages(file);
    return addWatermarkToPages(
      pages: pages,
      sourceName: sourceName,
      text: text,
      imageBytes: imageBytes,
      opacity: opacity,
      rotationDegrees: rotationDegrees,
      tile: tile,
      fontSize: fontSize,
      colorValue: colorValue,
    );
  }

  /// Page-list entry point for [addWatermark], split out so the
  /// composition logic can be exercised without needing a real PDF to
  /// render (pdfium) — only [exportMultiPagePdf]'s pure-Dart write path
  /// is under test there.
  static Future<File> addWatermarkToPages({
    required List<RenderedPdfPage> pages,
    required String sourceName,
    String? text,
    Uint8List? imageBytes,
    double opacity = 0.3,
    double rotationDegrees = -45,
    bool tile = true,
    double fontSize = 40,
    int colorValue = 0xFF808080,
  }) async {
    assert(
      (text != null) ^ (imageBytes != null),
      'Provide exactly one of text or imageBytes',
    );
    final document = pw.Document(compress: true);
    final imageProvider = imageBytes == null ? null : pw.MemoryImage(imageBytes);

    for (final page in pages) {
      final pageFormat = pdf_core.PdfPageFormat(page.width, page.height);
      final background = pw.MemoryImage(page.bytes);
      final watermarkChild = text != null
          ? pw.Text(
              text,
              style: pw.TextStyle(
                fontSize: fontSize,
                color: pdf_core.PdfColor.fromInt(colorValue),
              ),
            )
          : pw.Image(imageProvider!, width: fontSize * 2.4, height: fontSize * 2.4);

      document.addPage(
        pw.Page(
          pageFormat: pageFormat,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Stack(
            children: [
              pw.Positioned.fill(
                child: pw.Image(background, fit: pw.BoxFit.fill),
              ),
              pw.Positioned.fill(
                child: pw.Opacity(
                  opacity: opacity,
                  child: tile
                      ? _tiledWatermark(
                          child: watermarkChild,
                          pageWidth: page.width,
                          pageHeight: page.height,
                          rotationDegrees: rotationDegrees,
                          isText: text != null,
                          fontSize: fontSize,
                        )
                      : pw.Center(
                          child: pw.Transform.rotate(
                            angle: rotationDegrees * math.pi / 180,
                            child: watermarkChild,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final directory = await getApplicationDocumentsDirectory();
    final safeName = sourceName
        .replaceAll(RegExp(r'\.[Pp][Dd][Ff]$'), '')
        .replaceAll(RegExp(r'[^a-zA-Z0-9가-힣_-]'), '_');
    final output = File(
      '${directory.path}/${safeName}_watermarked_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await output.writeAsBytes(await document.save(), flush: true);
    return output;
  }

  /// Repeats [child] in a grid large enough to cover the page even after
  /// rotation: the grid is built inside a square whose side is the
  /// page's own diagonal, centered on the page, so a square that size
  /// always fully covers the page regardless of rotation angle.
  static pw.Widget _tiledWatermark({
    required pw.Widget child,
    required double pageWidth,
    required double pageHeight,
    required double rotationDegrees,
    required bool isText,
    required double fontSize,
  }) {
    final diagonal = math.sqrt(
      pageWidth * pageWidth + pageHeight * pageHeight,
    );
    final spacingX = isText ? fontSize * 6 : fontSize * 3.2;
    final spacingY = isText ? fontSize * 4 : fontSize * 3.2;
    final steps = (diagonal / math.min(spacingX, spacingY)).ceil() + 2;

    final tiles = <pw.Widget>[];
    for (var row = -steps ~/ 2; row <= steps ~/ 2; row++) {
      for (var col = -steps ~/ 2; col <= steps ~/ 2; col++) {
        tiles.add(
          pw.Positioned(
            left: diagonal / 2 + col * spacingX,
            top: diagonal / 2 + row * spacingY,
            child: child,
          ),
        );
      }
    }

    return pw.Center(
      child: pw.SizedBox(
        width: diagonal,
        height: diagonal,
        child: pw.Transform.rotate(
          angle: rotationDegrees * math.pi / 180,
          child: pw.Stack(children: tiles),
        ),
      ),
    );
  }

  static pw.Widget _buildPdfItem(
    EditorItem item,
    double pageWidth,
    double pageHeight,
  ) {
    final left = item.x * pageWidth;
    final top = item.y * pageHeight;
    final itemWidth = item.width * pageWidth;
    final itemHeight = item.height * pageHeight;

    late pw.Widget child;
    switch (item.type) {
      case EditorItemType.text:
        child = pw.Text(
          item.text ?? '',
          style: pw.TextStyle(
            fontSize: item.fontSize,
            color: pdf_core.PdfColor.fromInt(item.colorValue),
          ),
        );
        break;
      case EditorItemType.check:
        child = pw.Text('✓', style: pw.TextStyle(fontSize: itemHeight * 0.8));
        break;
      case EditorItemType.signature:
      case EditorItemType.image:
      case EditorItemType.stamp:
        child = item.bytes == null
            ? pw.SizedBox()
            : pw.Image(pw.MemoryImage(item.bytes!), fit: pw.BoxFit.contain);
        break;
      case EditorItemType.rect:
        child = pw.Container(
          color: pdf_core.PdfColor.fromInt(item.colorValue),
        );
        break;
      case EditorItemType.memo:
        child = pw.Container(
          color: pdf_core.PdfColor.fromInt(item.colorValue),
          padding: const pw.EdgeInsets.all(4),
          child: pw.Text(item.text ?? '', style: const pw.TextStyle(fontSize: 9)),
        );
        break;
      case EditorItemType.link:
        final url = item.linkUrl;
        final label = pw.Text(
          item.text ?? url ?? '',
          style: pw.TextStyle(
            fontSize: item.fontSize,
            color: pdf_core.PdfColors.blue,
            decoration: pw.TextDecoration.underline,
          ),
        );
        child = url == null || url.isEmpty
            ? label
            : pw.UrlLink(destination: url, child: label);
        break;
      case EditorItemType.drawing:
        child = pw.CustomPaint(
          size: pdf_core.PdfPoint(itemWidth, itemHeight),
          painter: (canvas, size) {
            if (item.points.length < 2) return;
            canvas
              ..setStrokeColor(pdf_core.PdfColor.fromInt(item.colorValue))
              ..setLineWidth(item.strokeWidth);
            final first = item.points.first;
            canvas.moveTo(
              first.dx * itemWidth,
              itemHeight - first.dy * itemHeight,
            );
            for (final point in item.points.skip(1)) {
              canvas.lineTo(
                point.dx * itemWidth,
                itemHeight - point.dy * itemHeight,
              );
            }
            canvas.strokePath();
          },
        );
        break;
    }

    return pw.Positioned(
      left: left,
      top: top,
      child: pw.SizedBox(
        width: itemWidth,
        height: itemHeight,
        child: pw.Transform.rotate(angle: item.rotation, child: child),
      ),
    );
  }
}

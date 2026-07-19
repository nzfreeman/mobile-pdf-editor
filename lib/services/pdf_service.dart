import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' as pdf_core;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../models/editor_item.dart';

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
    final document = pw.Document(compress: true);

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
        child = pw.Text(
          '✓',
          style: pw.TextStyle(fontSize: itemHeight * 0.8),
        );
        break;
      case EditorItemType.signature:
      case EditorItemType.image:
      case EditorItemType.stamp:
        child = item.bytes == null
            ? pw.SizedBox()
            : pw.Image(pw.MemoryImage(item.bytes!), fit: pw.BoxFit.contain);
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

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfx/pdfx.dart';

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
    final document = await PdfDocument.openFile(file.path);
    final result = <RenderedPdfPage>[];
    try {
      for (var pageNumber = 1; pageNumber <= document.pagesCount; pageNumber++) {
        final page = await document.getPage(pageNumber);
        try {
          final scale = math.min(2.0, 1800 / page.width);
          final rendered = await page.render(
            width: page.width * scale,
            height: page.height * scale,
            format: PdfPageImageFormat.png,
            backgroundColor: '#FFFFFFFF',
          );
          if (rendered == null) throw StateError('$pageNumber 페이지 렌더링 실패');
          result.add(RenderedPdfPage(
            bytes: rendered.bytes,
            width: page.width,
            height: page.height,
          ));
        } finally {
          await page.close();
        }
      }
    } finally {
      await document.close();
    }
    return result;
  }

  static Future<File> exportMultiPagePdf({
    required List<RenderedPdfPage> pages,
    required List<EditorItem> items,
    required String sourceName,
  }) async {
    final pdf = pw.Document(compress: true);

    for (var index = 0; index < pages.length; index++) {
      final page = pages[index];
      final pageItems = items.where((e) => e.pageIndex == index).toList();
      final pageFormat = PdfPageFormat(page.width, page.height);
      final background = pw.MemoryImage(page.bytes);

      pdf.addPage(pw.Page(
        pageFormat: pageFormat,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Stack(children: [
          pw.Positioned.fill(child: pw.Image(background, fit: pw.BoxFit.fill)),
          ...pageItems.map((item) => _buildPdfItem(item, page.width, page.height)),
        ]),
      ));
    }

    final directory = await getApplicationDocumentsDirectory();
    final safeName = sourceName
        .replaceAll(RegExp(r'\.[Pp][Dd][Ff]$'), '')
        .replaceAll(RegExp(r'[^a-zA-Z0-9가-힣_-]'), '_');
    final output = File(
      '${directory.path}/${safeName}_edited_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await output.writeAsBytes(await pdf.save(), flush: true);
    return output;
  }

  static pw.Widget _buildPdfItem(EditorItem item, double width, double height) {
    final left = item.x * width;
    final top = item.y * height;
    final itemWidth = item.width * width;
    final itemHeight = item.height * height;

    pw.Widget child;
    switch (item.type) {
      case EditorItemType.text:
        child = pw.Text(
          item.text ?? '',
          style: pw.TextStyle(fontSize: item.fontSize, color: PdfColor.fromInt(item.colorValue)),
        );
        break;
      case EditorItemType.check:
        child = pw.Text('✓', style: pw.TextStyle(fontSize: itemHeight * .8));
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
          size: PdfPoint(width, height),
          painter: (canvas, size) {
            if (item.points.length < 2) return;
            canvas
              ..setStrokeColor(PdfColor.fromInt(item.colorValue))
              ..setLineWidth(item.strokeWidth);
            final first = item.points.first;
            canvas.moveTo(first.dx * width, height - first.dy * height);
            for (final point in item.points.skip(1)) {
              canvas.lineTo(point.dx * width, height - point.dy * height);
            }
            canvas.strokePath();
          },
        );
        return pw.Positioned.fill(child: child);
    }

    return pw.Positioned(
      left: left,
      top: top,
      width: itemWidth,
      height: itemHeight,
      child: pw.Transform.rotate(angle: item.rotation, child: child),
    );
  }
}

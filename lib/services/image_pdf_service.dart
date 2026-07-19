import 'dart:io';

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
      final bytes = await imageFile.readAsBytes();
      final image = pw.MemoryImage(bytes);
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(18),
          build: (_) => pw.Center(
            child: pw.Image(image, fit: pw.BoxFit.contain),
          ),
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
}

import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

class OcrTextBlock {
  const OcrTextBlock({
    required this.text,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  /// Recognized text, and normalized (0.0-1.0) bounding box relative to the
  /// source image, matching the coordinate system used by [EditorItem].
  final String text;
  final double x;
  final double y;
  final double width;
  final double height;
}

class OcrService {
  static Future<List<OcrTextBlock>> recognizeText(Uint8List imageBytes) async {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) return [];

    final directory = await getTemporaryDirectory();
    final tempFile = File(
      '${directory.path}/ocr_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    await tempFile.writeAsBytes(imageBytes, flush: true);

    final recognizer = TextRecognizer(
      script: TextRecognitionScript.korean,
    );
    try {
      final inputImage = InputImage.fromFilePath(tempFile.path);
      final result = await recognizer.processImage(inputImage);
      final blocks = <OcrTextBlock>[];
      for (final block in result.blocks) {
        for (final line in block.lines) {
          final rect = line.boundingBox;
          blocks.add(
            OcrTextBlock(
              text: line.text,
              x: (rect.left / decoded.width).clamp(0.0, 1.0),
              y: (rect.top / decoded.height).clamp(0.0, 1.0),
              width: (rect.width / decoded.width).clamp(0.01, 1.0),
              height: (rect.height / decoded.height).clamp(0.01, 1.0),
            ),
          );
        }
      }
      return blocks;
    } finally {
      await recognizer.close();
      if (await tempFile.exists()) await tempFile.delete();
    }
  }
}

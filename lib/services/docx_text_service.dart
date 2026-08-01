import 'dart:io';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Best-effort plain-text extraction from a `.docx` file (a zip archive
/// containing `word/document.xml`, itself a flat run of WordprocessingML
/// elements). Only text content survives — fonts, styles, images, tables,
/// and headers/footers are not reproduced. That's an explicit, disclosed
/// limitation: a full docx→PDF layout engine is out of scope, but getting
/// the words onto a page is still useful.
class DocxTextService {
  DocxTextService._();

  static Future<String> extractText(File file) async {
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final documentEntry = archive.files.firstWhere(
      (entry) => entry.name == 'word/document.xml',
      orElse: () => throw const FormatException(
        'word/document.xml을 찾을 수 없습니다 (올바른 .docx 파일이 아닙니다).',
      ),
    );
    final xmlContent = String.fromCharCodes(documentEntry.content as List<int>);
    final document = XmlDocument.parse(xmlContent);

    final paragraphs = <String>[];
    for (final paragraph in document.findAllElements(
      'p',
      namespaceUri: '*',
    )) {
      final buffer = StringBuffer();
      for (final node in paragraph.descendantElements) {
        switch (node.name.local) {
          case 't':
            buffer.write(node.innerText);
          case 'tab':
            buffer.write('\t');
          case 'br':
          case 'cr':
            buffer.write('\n');
        }
      }
      paragraphs.add(buffer.toString());
    }

    final text = paragraphs.join('\n');
    if (text.trim().isEmpty) {
      throw const FormatException('문서에서 추출할 텍스트를 찾지 못했습니다.');
    }
    return text;
  }
}

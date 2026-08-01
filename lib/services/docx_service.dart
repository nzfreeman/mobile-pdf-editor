import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// A single run of text within a paragraph, carrying just the character
/// formatting WordprocessingML exposes at the run level (bold/italic/
/// underline). Font family/size and paragraph-level spacing are not
/// modeled — this covers the common case of emphasis within body text
/// and headings, not a full style engine.
class DocxTextSpan {
  const DocxTextSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
}

sealed class DocxBlock {}

/// [headingLevel] is 1-6 for `HeadingN` paragraph styles, 0 for `Title`,
/// and null for body text.
class DocxParagraph extends DocxBlock {
  DocxParagraph(this.spans, {this.headingLevel});
  final List<DocxTextSpan> spans;
  final int? headingLevel;
}

class DocxImage extends DocxBlock {
  DocxImage(this.bytes);
  final Uint8List bytes;
}

class DocxTable extends DocxBlock {
  DocxTable(this.rows);
  final List<List<String>> rows;
}

/// Parses a `.docx` file (a zip archive containing WordprocessingML) into
/// an ordered list of [DocxBlock]s, preserving paragraph-level bold/
/// italic/underline emphasis, inline images, and simple tables. This is
/// a deliberately partial reimplementation of Word's layout model: page
/// margins, custom fonts, precise spacing, headers/footers, footnotes,
/// nested tables, and floating (non-inline) images are not reproduced.
class DocxService {
  DocxService._();

  static Future<List<DocxBlock>> parse(File file) async {
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final documentEntry = archive.files.firstWhere(
      (entry) => entry.name == 'word/document.xml',
      orElse: () => throw const FormatException(
        'word/document.xml을 찾을 수 없습니다 (올바른 .docx 파일이 아닙니다).',
      ),
    );
    final document = XmlDocument.parse(
      utf8.decode(documentEntry.content as List<int>),
    );

    final relsEntry = archive.files.firstWhereOrNull(
      (entry) => entry.name == 'word/_rels/document.xml.rels',
    );
    final relationships = <String, String>{};
    if (relsEntry != null) {
      final relsXml = XmlDocument.parse(
        utf8.decode(relsEntry.content as List<int>),
      );
      for (final rel in relsXml.findAllElements('Relationship')) {
        final id = rel.getAttribute('Id');
        final target = rel.getAttribute('Target');
        if (id != null && target != null) relationships[id] = target;
      }
    }
    final mediaById = <String, Uint8List>{
      for (final entry in archive.files)
        if (entry.name.startsWith('word/media/'))
          entry.name.substring('word/'.length): Uint8List.fromList(
            entry.content as List<int>,
          ),
    };

    final body = document.findAllElements('body', namespaceUri: '*').firstOrNull;
    if (body == null) return [];

    final blocks = <DocxBlock>[];
    for (final child in body.childElements) {
      switch (child.name.local) {
        case 'p':
          blocks.addAll(_parseParagraph(child, relationships, mediaById));
        case 'tbl':
          blocks.add(_parseTable(child));
      }
    }

    if (blocks.isEmpty) {
      throw const FormatException('문서에서 추출할 내용을 찾지 못했습니다.');
    }
    return blocks;
  }

  static List<DocxBlock> _parseParagraph(
    XmlElement paragraph,
    Map<String, String> relationships,
    Map<String, Uint8List> mediaById,
  ) {
    final styleVal = paragraph
        .findAllElements('pStyle', namespaceUri: '*')
        .firstOrNull
        ?.getAttribute('w:val');
    final headingLevel = _headingLevelOf(styleVal);

    final spans = <DocxTextSpan>[];
    final images = <DocxImage>[];
    for (final run in paragraph.findElements('r', namespaceUri: '*')) {
      final rPr = run.findElements('rPr', namespaceUri: '*').firstOrNull;
      final bold = rPr?.findElements('b', namespaceUri: '*').firstOrNull != null;
      final italic = rPr?.findElements('i', namespaceUri: '*').firstOrNull != null;
      final underline =
          rPr?.findElements('u', namespaceUri: '*').firstOrNull != null;

      final buffer = StringBuffer();
      for (final node in run.children.whereType<XmlElement>()) {
        switch (node.name.local) {
          case 't':
            buffer.write(node.innerText);
          case 'tab':
            buffer.write('\t');
          case 'br':
          case 'cr':
            buffer.write('\n');
          case 'drawing':
            final embedId = node
                .findAllElements('blip', namespaceUri: '*')
                .firstOrNull
                ?.getAttribute('r:embed');
            final target = embedId == null ? null : relationships[embedId];
            final imageBytes = target == null ? null : mediaById[target];
            if (imageBytes != null) images.add(DocxImage(imageBytes));
        }
      }
      if (buffer.isNotEmpty) {
        spans.add(
          DocxTextSpan(
            buffer.toString(),
            bold: bold,
            italic: italic,
            underline: underline,
          ),
        );
      }
    }

    final result = <DocxBlock>[];
    if (spans.isNotEmpty || headingLevel != null) {
      result.add(DocxParagraph(spans, headingLevel: headingLevel));
    }
    result.addAll(images);
    return result;
  }

  static DocxTable _parseTable(XmlElement table) {
    final rows = <List<String>>[];
    for (final row in table.findElements('tr', namespaceUri: '*')) {
      final cells = <String>[];
      for (final cell in row.findElements('tc', namespaceUri: '*')) {
        final buffer = StringBuffer();
        for (final textNode in cell.findAllElements('t', namespaceUri: '*')) {
          buffer.write(textNode.innerText);
        }
        cells.add(buffer.toString());
      }
      rows.add(cells);
    }
    return DocxTable(rows);
  }

  static int? _headingLevelOf(String? styleVal) {
    if (styleVal == null) return null;
    if (styleVal == 'Title') return 0;
    final match = RegExp(r'^Heading(\d)$').firstMatch(styleVal);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
  T? firstWhereOrNull(bool Function(T) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}

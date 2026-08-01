import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_pdf_editor/services/docx_service.dart';

const _documentXml = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>제목입니다</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:rPr><w:b/></w:rPr><w:t>굵은 글씨</w:t></w:r>
      <w:r><w:t> 그리고 </w:t></w:r>
      <w:r><w:rPr><w:i/></w:rPr><w:t>기울임</w:t></w:r>
    </w:p>
    <w:tbl>
      <w:tr>
        <w:tc><w:p><w:r><w:t>이름</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>나이</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>철수</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>30</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>
  </w:body>
</w:document>
''';

File _buildDocx(String tempDir) {
  final archive = Archive();
  archive.addFile(
    ArchiveFile.string('word/document.xml', _documentXml),
  );
  final bytes = ZipEncoder().encode(archive);
  final file = File('$tempDir/sample.docx');
  file.writeAsBytesSync(bytes);
  return file;
}

void main() {
  test('parses headings, run-level emphasis, and a simple table', () async {
    final tempDir = Directory.systemTemp.createTempSync('docx_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final file = _buildDocx(tempDir.path);

    final blocks = await DocxService.parse(file);

    final heading = blocks.whereType<DocxParagraph>().first;
    expect(heading.headingLevel, 1);
    expect(heading.spans.single.text, '제목입니다');

    final body = blocks.whereType<DocxParagraph>().elementAt(1);
    expect(body.headingLevel, isNull);
    expect(body.spans[0].text, '굵은 글씨');
    expect(body.spans[0].bold, isTrue);
    expect(body.spans[2].text, '기울임');
    expect(body.spans[2].italic, isTrue);

    final table = blocks.whereType<DocxTable>().single;
    expect(table.rows, [
      ['이름', '나이'],
      ['철수', '30'],
    ]);
  });

  test('throws a clear error for a docx with no extractable content', () async {
    final tempDir = Directory.systemTemp.createTempSync('docx_test_empty');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final archive = Archive();
    archive.addFile(
      ArchiveFile.string(
        'word/document.xml',
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body></w:body></w:document>',
      ),
    );
    final file = File('${tempDir.path}/empty.docx');
    file.writeAsBytesSync(ZipEncoder().encode(archive));

    expect(() => DocxService.parse(file), throwsFormatException);
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'pdf_document.dart';
import 'pdf_objects.dart';

class PdfEdit {
  const PdfEdit({
    required this.streamRef,
    required this.start,
    required this.end,
    required this.replacement,
  });

  final PdfRef streamRef;

  /// Byte range within the stream's own *decoded* bytes to replace.
  final int start;
  final int end;
  final Uint8List replacement;
}

class PdfNativeEditException implements Exception {
  PdfNativeEditException(this.message);
  final String message;

  @override
  String toString() => 'PdfNativeEditException: $message';
}

/// Applies [edits] to [doc]/[originalBytes] by appending a PDF
/// incremental update: new versions of only the edited content-stream
/// objects, followed by a fresh xref section whose `/Prev` points back at
/// the original file's own xref. Every byte of the original file is left
/// untouched — the new revision is purely additive — which is the same
/// technique PDF viewers use for annotations/form fills and is far lower
/// risk than regenerating the whole file.
Uint8List applyIncrementalEdits(
  PdfDocument doc,
  Uint8List originalBytes,
  List<PdfEdit> edits,
) {
  if (edits.isEmpty) return originalBytes;

  final byStream = <PdfRef, List<PdfEdit>>{};
  for (final edit in edits) {
    byStream.putIfAbsent(edit.streamRef, () => []).add(edit);
  }

  final output = BytesBuilder();
  output.add(originalBytes);
  if (originalBytes.isEmpty || originalBytes.last != 10) {
    output.addByte(10);
  }

  final newOffsets = <int, int>{};
  var writeOffset = output.length;

  for (final entry in byStream.entries) {
    final ref = entry.key;
    if (doc.directOffsetOf(ref.objectNumber) == null) {
      throw PdfNativeEditException(
        'Object ${ref.objectNumber} is stored in a compressed object '
        'stream; this writer only supports directly-stored content '
        'streams.',
      );
    }
    final streamObj = doc.getObject(ref);
    if (streamObj is! PdfStreamObj) {
      throw PdfNativeEditException('Object ${ref.objectNumber} is not a stream');
    }
    var decoded = doc.decodeStream(streamObj);

    final sortedEdits = [...entry.value]
      ..sort((a, b) => b.start.compareTo(a.start));
    for (final edit in sortedEdits) {
      if (edit.start < 0 || edit.end > decoded.length || edit.start > edit.end) {
        throw PdfNativeEditException('Edit range out of bounds');
      }
      decoded = Uint8List.fromList([
        ...decoded.sublist(0, edit.start),
        ...edit.replacement,
        ...decoded.sublist(edit.end),
      ]);
    }

    // Written uncompressed for correctness/simplicity: we don't
    // re-implement the original predictor pipeline, only decode it.
    final newDict = Map<String, PdfObject>.from(streamObj.dict.entries)
      ..remove('Filter')
      ..remove('DecodeParms')
      ..['Length'] = PdfNumber(decoded.length);

    final objectBytes = BytesBuilder();
    objectBytes.add(
      utf8.encode('${ref.objectNumber} ${ref.generation} obj\n'),
    );
    objectBytes.add(utf8.encode(_encodeDict(newDict)));
    objectBytes.add(utf8.encode('\nstream\n'));
    objectBytes.add(decoded);
    objectBytes.add(utf8.encode('\nendstream\nendobj\n'));

    newOffsets[ref.objectNumber] = writeOffset;
    final bytes = objectBytes.toBytes();
    output.add(bytes);
    writeOffset += bytes.length;
  }

  final xrefOffset = writeOffset;
  final root = doc.trailer['Root'];
  final info = doc.trailer['Info'];
  final originalSize = (doc.trailer['Size'] as PdfNumber?)?.intValue ?? 0;
  final rootObjNum = root is PdfRef ? root.objectNumber : 0;
  final maxNewObjNum = newOffsets.keys.reduce((a, b) => a > b ? a : b);
  final size = [
    originalSize,
    rootObjNum + 1,
    maxNewObjNum + 1,
  ].reduce((a, b) => a > b ? a : b);
  final previousStartXref = _findLastStartXref(originalBytes);

  final xrefBuffer = StringBuffer()..writeln('xref');
  final sortedObjNums = newOffsets.keys.toList()..sort();
  for (final objNum in sortedObjNums) {
    xrefBuffer
      ..writeln('$objNum 1')
      ..writeln('${newOffsets[objNum]!.toString().padLeft(10, '0')} 00000 n ');
  }
  xrefBuffer.writeln('trailer');
  final trailerEntries = <String, PdfObject>{
    'Size': PdfNumber(size),
    if (root != null) 'Root': root,
    if (info != null) 'Info': info,
    if (previousStartXref != null) 'Prev': PdfNumber(previousStartXref),
  };
  xrefBuffer.write(_encodeDict(trailerEntries));
  xrefBuffer
    ..writeln()
    ..writeln('startxref')
    ..writeln(xrefOffset)
    ..write('%%EOF');

  output.add(utf8.encode(xrefBuffer.toString()));
  return output.toBytes();
}

String _encodeDict(Map<String, PdfObject> entries) {
  final buffer = StringBuffer('<< ');
  entries.forEach((key, value) {
    buffer
      ..write('/$key ')
      ..write(_encodeObject(value))
      ..write(' ');
  });
  buffer.write('>>');
  return buffer.toString();
}

String _encodeObject(PdfObject obj) {
  return switch (obj) {
    PdfNumber n => n.value % 1 == 0 ? n.intValue.toString() : n.value.toString(),
    PdfName n => '/${n.value}',
    PdfBool b => b.value.toString(),
    PdfNull _ => 'null',
    PdfRef r => '${r.objectNumber} ${r.generation} R',
    PdfArrayObj a => '[${a.items.map(_encodeObject).join(' ')}]',
    PdfDictionaryObj d => _encodeDict(d.entries),
    PdfLiteralString s => '(${latin1.decode(s.bytes, allowInvalid: true)})',
    PdfStreamObj _ => throw PdfNativeEditException(
        'Cannot inline-encode a stream object as a dictionary value',
      ),
  };
}

int? _findLastStartXref(Uint8List bytes) {
  const marker = 'startxref';
  final text = latin1.decode(bytes, allowInvalid: true);
  final idx = text.lastIndexOf(marker);
  if (idx < 0) return null;
  final rest = text.substring(idx + marker.length).trimLeft();
  final match = RegExp(r'^\d+').firstMatch(rest);
  if (match == null) return null;
  return int.tryParse(match.group(0)!);
}

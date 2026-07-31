import 'dart:convert';
import 'dart:typed_data';

import 'pdf_document.dart';
import 'pdf_objects.dart';

class PdfNativeEditException implements Exception {
  PdfNativeEditException(this.message);
  final String message;

  @override
  String toString() => 'PdfNativeEditException: $message';
}

/// A fully-formed object body (everything between `N G obj` and `endobj`,
/// exclusive) to write under [objectNumber]/[generation] — either a brand
/// new object (a number [PdfDocument.allocateNewObjectNumbers] handed
/// out) or a new revision superseding an existing one.
class PdfObjectWrite {
  const PdfObjectWrite({
    required this.objectNumber,
    required this.generation,
    required this.body,
  });

  final int objectNumber;
  final int generation;
  final Uint8List body;
}

/// Applies [writes] to [doc]/[originalBytes] by appending a PDF
/// incremental update: the new/superseding objects, followed by a fresh
/// xref section whose `/Prev` points back at the original file's own
/// xref. Every byte of the original file is left untouched — the new
/// revision is purely additive — which is the same technique PDF viewers
/// use for annotations/form fills and is far lower risk than
/// regenerating the whole file.
Uint8List applyObjectWrites(
  PdfDocument doc,
  Uint8List originalBytes,
  List<PdfObjectWrite> writes,
) {
  if (writes.isEmpty) return originalBytes;

  final output = BytesBuilder();
  output.add(originalBytes);
  if (originalBytes.isEmpty || originalBytes.last != 10) {
    output.addByte(10);
  }

  final newOffsets = <int, int>{};
  var writeOffset = output.length;

  for (final write in writes) {
    final objectBytes = BytesBuilder();
    objectBytes.add(
      utf8.encode('${write.objectNumber} ${write.generation} obj\n'),
    );
    objectBytes.add(write.body);
    objectBytes.add(utf8.encode('\nendobj\n'));

    newOffsets[write.objectNumber] = writeOffset;
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
  xrefBuffer.write(encodeDict(trailerEntries));
  xrefBuffer
    ..writeln()
    ..writeln('startxref')
    ..writeln(xrefOffset)
    ..write('%%EOF');

  output.add(utf8.encode(xrefBuffer.toString()));
  return output.toBytes();
}

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

/// Convenience wrapper over [applyObjectWrites] for the common case of
/// splicing byte ranges within one or more existing content streams.
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

  final writes = <PdfObjectWrite>[];
  for (final entry in byStream.entries) {
    final ref = entry.key;
    writes.add(buildEditedStreamWrite(doc, ref, entry.value));
  }
  return applyObjectWrites(doc, originalBytes, writes);
}

/// Builds a [PdfObjectWrite] for stream object [ref] with [edits] applied
/// to its decoded bytes. Written uncompressed for correctness/simplicity
/// — this reader doesn't re-implement the original predictor pipeline,
/// only decode it.
PdfObjectWrite buildEditedStreamWrite(
  PdfDocument doc,
  PdfRef ref,
  List<PdfEdit> edits,
) {
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

  final sortedEdits = [...edits]..sort((a, b) => b.start.compareTo(a.start));
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

  final newDict = Map<String, PdfObject>.from(streamObj.dict.entries)
    ..remove('Filter')
    ..remove('DecodeParms')
    ..['Length'] = PdfNumber(decoded.length);

  final body = BytesBuilder();
  body.add(utf8.encode(encodeDict(newDict)));
  body.add(utf8.encode('\nstream\n'));
  body.add(decoded);
  body.add(utf8.encode('\nendstream'));

  return PdfObjectWrite(
    objectNumber: ref.objectNumber,
    generation: ref.generation,
    body: body.toBytes(),
  );
}

String encodeDict(Map<String, PdfObject> entries) {
  final buffer = StringBuffer('<< ');
  entries.forEach((key, value) {
    buffer
      ..write('/$key ')
      ..write(encodeObject(value))
      ..write(' ');
  });
  buffer.write('>>');
  return buffer.toString();
}

String encodeObject(PdfObject obj) {
  return switch (obj) {
    PdfNumber n => n.value % 1 == 0 ? n.intValue.toString() : n.value.toString(),
    PdfName n => '/${n.value}',
    PdfBool b => b.value.toString(),
    PdfNull _ => 'null',
    PdfRef r => '${r.objectNumber} ${r.generation} R',
    PdfArrayObj a => '[${a.items.map(encodeObject).join(' ')}]',
    PdfDictionaryObj d => encodeDict(d.entries),
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

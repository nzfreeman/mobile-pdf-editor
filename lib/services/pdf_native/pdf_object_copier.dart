import 'dart:typed_data';

import 'pdf_document.dart';
import 'pdf_incremental_writer.dart'
    show PdfNativeEditException, encodeDict, encodeObject;
import 'pdf_objects.dart';

/// Deep-copies reachable PDF objects (fonts, images/XObjects, annotations
/// and their appearance streams, form-field parents, etc.) from one or
/// more source [PdfDocument]s into a single fresh, renumbered object
/// space — the building block for structure-preserving merge/split,
/// where pages are relocated wholesale rather than rasterized and
/// rebuilt. Streams are copied byte-for-byte (still encoded/compressed,
/// never decoded) so original compression, embedded fonts, vector
/// content, and any encoding this reader doesn't otherwise understand
/// all survive untouched.
class PdfObjectCopier {
  PdfObjectCopier();

  final Map<(PdfDocument, int), int> _mapping = {};
  final Map<int, PdfObject> _objects = {};
  int _nextObjNum = 1;

  int _allocate() => _nextObjNum++;

  /// Copies [page] (skipping its `/Parent` — the caller sets that once
  /// the destination Pages tree node exists) and everything it
  /// transitively references. Returns the new object number.
  int copyPage(PdfDocument doc, PdfDictionaryObj page) {
    final oldRef = doc.refOf(page);
    if (oldRef == null) {
      throw PdfNativeEditException("Couldn't determine the page's own object reference");
    }
    final key = (doc, oldRef.objectNumber);
    final existing = _mapping[key];
    if (existing != null) return existing;

    final newNum = _allocate();
    _mapping[key] = newNum;

    final entries = <String, PdfObject>{};
    page.entries.forEach((k, v) {
      if (k == 'Parent') return;
      entries[k] = _remap(doc, v);
    });
    // Many producers put MediaBox/Resources/CropBox/Rotate on an
    // ancestor Pages node rather than repeating them on every leaf page
    // (perfectly legal — they're inheritable). Since we deliberately
    // don't copy /Parent (that would drag in the whole original Pages
    // tree), a page relying on that inheritance would otherwise lose
    // its dimensions/resources/rotation entirely in the output. Inline
    // whichever of these the page doesn't already define directly.
    for (final key in const ['MediaBox', 'Resources', 'CropBox', 'Rotate']) {
      if (entries.containsKey(key)) continue;
      final inherited = doc.inheritedAttribute(page, key);
      if (inherited != null) entries[key] = _remap(doc, inherited);
    }
    _objects[newNum] = PdfDictionaryObj(entries);
    return newNum;
  }

  /// Copies an arbitrary referenced object (font, image, annotation,
  /// parent form field, etc.) and everything *it* references, including
  /// following `/Parent` where present (needed to preserve form-field
  /// hierarchies) — the recursion is naturally bounded by the
  /// `_mapping` cache short-circuiting anything already copied.
  int copyRef(PdfDocument doc, PdfRef oldRef) {
    final key = (doc, oldRef.objectNumber);
    final existing = _mapping[key];
    if (existing != null) return existing;

    final newNum = _allocate();
    _mapping[key] = newNum;

    final obj = doc.getObject(oldRef);
    _objects[newNum] = obj == null ? const PdfNull() : _remap(doc, obj);
    return newNum;
  }

  /// Sets `/Parent` on a previously copied page or field object — call
  /// once the destination Pages tree (or parent field) object number is
  /// known.
  void setParent(int objNum, PdfRef parentRef) {
    final obj = _objects[objNum];
    if (obj is PdfDictionaryObj) {
      obj.entries['Parent'] = parentRef;
    }
  }

  /// Allocates a fresh object number for a new object the caller builds
  /// directly (e.g. the merged Pages tree node or Catalog) rather than
  /// copying from a source document.
  int allocateNew(PdfObject object) {
    final newNum = _allocate();
    _objects[newNum] = object;
    return newNum;
  }

  void replace(int objNum, PdfObject object) {
    _objects[objNum] = object;
  }

  PdfObject _remap(PdfDocument doc, PdfObject obj) {
    switch (obj) {
      case PdfRef r:
        return PdfRef(copyRef(doc, r), 0);
      case PdfArrayObj a:
        return PdfArrayObj(a.items.map((item) => _remap(doc, item)).toList());
      case PdfDictionaryObj d:
        final entries = <String, PdfObject>{};
        d.entries.forEach((k, v) => entries[k] = _remap(doc, v));
        return PdfDictionaryObj(entries);
      case PdfStreamObj s:
        final entries = <String, PdfObject>{};
        s.dict.entries.forEach((k, v) => entries[k] = _remap(doc, v));
        return PdfStreamObj(PdfDictionaryObj(entries), s.rawBytes);
      default:
        return obj;
    }
  }

  /// Serializes every copied/allocated object into a fresh, standalone
  /// PDF file (its own classic xref table — not an incremental update,
  /// since this combines objects that may come from several distinct
  /// source files) with [rootObjNum] as `/Root`.
  Uint8List write({required int rootObjNum}) {
    final output = BytesBuilder();
    output.add('%PDF-1.7\n%\xE2\xE3\xCF\xD3\n'.codeUnits);

    final offsets = <int, int>{};
    final sortedObjNums = _objects.keys.toList()..sort();
    for (final objNum in sortedObjNums) {
      offsets[objNum] = output.length;
      final obj = _objects[objNum]!;
      output.add('$objNum 0 obj\n'.codeUnits);
      if (obj is PdfStreamObj) {
        final dictWithLength = Map<String, PdfObject>.from(obj.dict.entries)
          ..['Length'] = PdfNumber(obj.rawBytes.length);
        output.add(encodeDict(dictWithLength).codeUnits);
        output.add('\nstream\n'.codeUnits);
        output.add(obj.rawBytes);
        output.add('\nendstream'.codeUnits);
      } else {
        output.add(encodeObject(obj).codeUnits);
      }
      output.add('\nendobj\n'.codeUnits);
    }

    final xrefOffset = output.length;
    final size = sortedObjNums.isEmpty ? 1 : sortedObjNums.last + 1;
    final xref = StringBuffer()
      ..writeln('xref')
      ..writeln('0 $size')
      ..writeln('0000000000 65535 f ');
    for (var i = 1; i < size; i++) {
      final offset = offsets[i];
      xref.writeln(
        '${(offset ?? 0).toString().padLeft(10, '0')} 00000 '
        '${offset == null ? 'f' : 'n'} ',
      );
    }
    xref
      ..writeln('trailer')
      ..writeln('<< /Size $size /Root $rootObjNum 0 R >>')
      ..writeln('startxref')
      ..writeln(xrefOffset)
      ..write('%%EOF');
    output.add(xref.toString().codeUnits);

    return output.toBytes();
  }
}

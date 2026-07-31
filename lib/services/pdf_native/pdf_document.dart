import 'dart:typed_data';

import 'pdf_lexer.dart';
import 'pdf_objects.dart';
import 'pdf_stream_filters.dart';

class PdfParseException implements Exception {
  PdfParseException(this.message);
  final String message;

  @override
  String toString() => 'PdfParseException: $message';
}

class _XrefEntry {
  const _XrefEntry.direct(this.offset)
    : streamObjectNumber = null,
      indexInStream = null;
  const _XrefEntry.compressed(this.streamObjectNumber, this.indexInStream)
    : offset = null;

  final int? offset;
  final int? streamObjectNumber;
  final int? indexInStream;
}

typedef _RefResolver = PdfObject? Function(PdfRef ref);

/// A read/parse view over a PDF file: resolves the xref table/streams,
/// parses individual objects on demand, and decodes stream filters.
///
/// This intentionally supports only what real-world text-editing needs:
/// classic xref tables, xref streams, object streams, and FlateDecode
/// (with PNG predictors) — by far the dominant combination produced by
/// modern PDF writers. Encrypted documents and exotic filters are not
/// supported and will surface as a [PdfParseException] or missing objects,
/// which callers should treat as "fall back to the OCR-based edit path".
class PdfDocument {
  PdfDocument._(this.bytes, this._xref, this.trailer);

  final Uint8List bytes;
  final Map<int, _XrefEntry> _xref;
  final PdfDictionaryObj trailer;
  final Map<int, PdfObject> _cache = {};

  static PdfDocument parse(Uint8List bytes) {
    final startXrefOffset = _findLastStartXref(bytes);
    if (startXrefOffset == null) {
      throw PdfParseException('No startxref found');
    }
    final xref = <int, _XrefEntry>{};
    final trailerEntries = <String, PdfObject>{};
    final visitedOffsets = <int>{};
    int? nextOffset = startXrefOffset;
    var sawAnyTrailer = false;

    while (nextOffset != null && visitedOffsets.add(nextOffset)) {
      final section = _parseXrefSection(bytes, nextOffset);
      for (final entry in section.entries.entries) {
        xref.putIfAbsent(entry.key, () => entry.value);
      }
      sawAnyTrailer = true;
      for (final entry in section.trailer.entries.entries) {
        trailerEntries.putIfAbsent(entry.key, () => entry.value);
      }
      final hybrid = section.trailer['XRefStm'];
      if (hybrid is PdfNumber) {
        final hybridSection = _parseXrefSection(bytes, hybrid.intValue);
        for (final entry in hybridSection.entries.entries) {
          xref.putIfAbsent(entry.key, () => entry.value);
        }
      }
      final prev = section.trailer['Prev'];
      nextOffset = prev is PdfNumber ? prev.intValue : null;
    }

    if (!sawAnyTrailer || !trailerEntries.containsKey('Root')) {
      throw PdfParseException('No trailer with /Root found');
    }
    if (trailerEntries.containsKey('Encrypt')) {
      // Encryption isn't implemented anywhere in this reader: string and
      // stream bytes would still be ciphertext after "successfully"
      // parsing the (unencrypted) object structure around them. Silently
      // continuing would produce a file that *parses* fine but whose
      // content streams/strings are garbage — exactly the kind of
      // silent-corruption failure mode this reader should never have.
      // Fail loudly here instead, once, for every pdf_native feature.
      throw PdfParseException(
        'Encrypted PDFs are not supported by this reader',
      );
    }
    return PdfDocument._(bytes, xref, PdfDictionaryObj(trailerEntries));
  }

  PdfObject? getObject(PdfRef ref) {
    final cached = _cache[ref.objectNumber];
    if (cached != null) return cached;
    final entry = _xref[ref.objectNumber];
    if (entry == null) return null;

    PdfObject? result;
    if (entry.offset != null) {
      result = _parseObjectAt(entry.offset!);
    } else if (entry.streamObjectNumber != null) {
      result = _parseFromObjectStream(
        entry.streamObjectNumber!,
        entry.indexInStream!,
      );
    }
    if (result != null) _cache[ref.objectNumber] = result;
    return result;
  }

  /// Byte offset of object [objectNumber] in the original file, if it was
  /// stored directly (not inside an object stream) — used by the
  /// incremental-update writer to splice edited stream bytes back in.
  int? directOffsetOf(int objectNumber) => _xref[objectNumber]?.offset;

  /// The indirect reference [obj] was originally loaded through, if any
  /// — found via the parse cache (which always returns the same instance
  /// for a given ref), so this only works for objects previously fetched
  /// through [getObject]/[resolve]/[pages]. Used when we need to graft a
  /// modified revision of an object we only have a resolved value for
  /// (e.g. rewriting a Page's Resources).
  PdfRef? refOf(PdfObject obj) {
    for (final entry in _cache.entries) {
      if (identical(entry.value, obj)) return PdfRef(entry.key, 0);
    }
    return null;
  }

  /// Lowest object number guaranteed not to collide with any object
  /// already in the file — the starting point for allocating new objects
  /// (e.g. an embedded fallback font) in an incremental update.
  int allocateNewObjectNumbers(int count) {
    var highest = (trailer['Size'] as PdfNumber?)?.intValue ?? 0;
    for (final objNum in _xref.keys) {
      if (objNum >= highest) highest = objNum + 1;
    }
    return highest;
  }

  /// Resolves indirect references to their target object; returns non-ref
  /// objects unchanged.
  PdfObject? resolve(PdfObject? obj) {
    var current = obj;
    var hops = 0;
    while (current is PdfRef && hops < 32) {
      current = getObject(current);
      hops++;
    }
    return current;
  }

  Uint8List decodeStream(PdfStreamObj stream) {
    var data = stream.rawBytes;
    final filterObj = resolve(stream.dict['Filter']);
    final parmsObj = resolve(stream.dict['DecodeParms']);
    final filters = switch (filterObj) {
      PdfName name => [name.value],
      PdfArrayObj array => array.items
          .map((item) => (resolve(item) as PdfName?)?.value)
          .whereType<String>()
          .toList(),
      _ => <String>[],
    };
    final parmsList = switch (parmsObj) {
      PdfDictionaryObj dict => [dict],
      PdfArrayObj array => array.items
          .map((item) => resolve(item))
          .whereType<PdfDictionaryObj>()
          .toList(),
      _ => <PdfDictionaryObj?>[],
    };

    for (var i = 0; i < filters.length; i++) {
      final parms = i < parmsList.length ? parmsList[i] : null;
      switch (filters[i]) {
        case 'FlateDecode':
        case 'Fl':
          final inflated = inflate(data);
          if (inflated == null) return data;
          data = _applyPredictor(inflated, parms);
        case 'ASCII85Decode':
        case 'A85':
          data = decodeAscii85(data);
        default:
          // Unsupported filter (LZW/DCT/CCITT/JPX/encryption, etc.) —
          // return as-is; callers treat undecodable content as
          // "can't edit this".
          return data;
      }
    }
    return data;
  }

  Uint8List _applyPredictor(Uint8List data, PdfDictionaryObj? parms) {
    if (parms == null) return data;
    final predictor =
        (resolve(parms['Predictor']) as PdfNumber?)?.intValue ?? 1;
    if (predictor < 10) return data;
    final columns = (resolve(parms['Columns']) as PdfNumber?)?.intValue ?? 1;
    final colors = (resolve(parms['Colors']) as PdfNumber?)?.intValue ?? 1;
    final bpc =
        (resolve(parms['BitsPerComponent']) as PdfNumber?)?.intValue ?? 8;
    return undoPngPredictor(
      data,
      columns: columns,
      colors: colors,
      bitsPerComponent: bpc,
    );
  }

  List<PdfDictionaryObj> get pages {
    final root = resolve(trailer['Root']);
    if (root is! PdfDictionaryObj) return [];
    final pagesRoot = resolve(root['Pages']);
    if (pagesRoot is! PdfDictionaryObj) return [];
    final result = <PdfDictionaryObj>[];
    _collectPages(pagesRoot, result, {});
    return result;
  }

  void _collectPages(
    PdfDictionaryObj node,
    List<PdfDictionaryObj> result,
    Set<PdfDictionaryObj> visited,
  ) {
    if (!visited.add(node)) return;
    final type = (resolve(node['Type']) as PdfName?)?.value;
    if (type == 'Page') {
      result.add(node);
      return;
    }
    final kids = resolve(node['Kids']);
    if (kids is PdfArrayObj) {
      for (final kidRef in kids.items) {
        final kid = resolve(kidRef);
        if (kid is PdfDictionaryObj) _collectPages(kid, result, visited);
      }
    }
  }

  /// Walks up the page's ancestor tree to find an inheritable attribute
  /// (Resources, MediaBox, etc. can be defined on a Pages node instead of
  /// the leaf Page).
  PdfObject? inheritedAttribute(PdfDictionaryObj page, String key) {
    PdfObject? node = page;
    var hops = 0;
    while (node is PdfDictionaryObj && hops < 32) {
      final value = node[key];
      if (value != null) return resolve(value);
      node = resolve(node['Parent']);
      hops++;
    }
    return null;
  }

  /// Concatenated, decoded content stream bytes for [page], plus which
  /// underlying stream object each output byte range came from (needed so
  /// edits can be written back to the correct object).
  ({Uint8List bytes, List<(PdfRef, int, int)> segments}) pageContent(
    PdfDictionaryObj page,
  ) {
    final contents = page['Contents'];
    final refs = <PdfRef>[];
    if (contents is PdfRef) {
      refs.add(contents);
    } else {
      final resolved = resolve(contents);
      if (resolved is PdfArrayObj) {
        for (final item in resolved.items) {
          if (item is PdfRef) refs.add(item);
        }
      }
    }

    final out = BytesBuilder();
    final segments = <(PdfRef, int, int)>[];
    for (final ref in refs) {
      final obj = getObject(ref);
      if (obj is! PdfStreamObj) continue;
      final decoded = decodeStream(obj);
      segments.add((ref, out.length, out.length + decoded.length));
      out.add(decoded);
      out.addByte(10);
    }
    return (bytes: out.toBytes(), segments: segments);
  }

  PdfObject? _parseObjectAt(int offset) {
    final lexer = PdfLexer(bytes, offset);
    final numTok = lexer.next();
    final genTok = lexer.next();
    final objTok = lexer.next();
    if (numTok.type != PdfTokenType.number ||
        genTok.type != PdfTokenType.number ||
        objTok.type != PdfTokenType.keyword ||
        objTok.text != 'obj') {
      return null;
    }
    return _parseValue(bytes, lexer, getObject);
  }

  PdfObject? _parseFromObjectStream(int streamObjNum, int index) {
    final streamObj = getObject(PdfRef(streamObjNum, 0));
    if (streamObj is! PdfStreamObj) return null;
    final decoded = decodeStream(streamObj);
    final n = (resolve(streamObj.dict['N']) as PdfNumber?)?.intValue ?? 0;
    final first =
        (resolve(streamObj.dict['First']) as PdfNumber?)?.intValue ?? 0;

    final headerLexer = PdfLexer(decoded, 0);
    final offsets = <int>[];
    for (var i = 0; i < n; i++) {
      headerLexer.next(); // object number (unused: index-based lookup below)
      final offsetTok = headerLexer.next();
      if (offsetTok.type == PdfTokenType.number) {
        offsets.add(offsetTok.number!.toInt());
      }
    }
    if (index >= offsets.length) return null;
    final objLexer = PdfLexer(decoded, first + offsets[index]);
    return _parseValue(decoded, objLexer, getObject);
  }
}

/// Recursive-descent parser for a single PDF value (number/name/string/
/// array/dictionary/stream/boolean/null/indirect-reference). Free function
/// (rather than a [PdfDocument] method) so it can be reused while
/// bootstrapping the xref table, before a document object exists.
PdfObject _parseValue(
  Uint8List bytes,
  PdfLexer lexer, [
  _RefResolver? resolveRef,
]) {
  final token = lexer.next();
  return _parseValueFromToken(bytes, lexer, token, resolveRef);
}

PdfObject _parseValueFromToken(
  Uint8List bytes,
  PdfLexer lexer,
  PdfToken token,
  _RefResolver? resolveRef,
) {
  switch (token.type) {
    case PdfTokenType.number:
      final savedPos1 = lexer.pos;
      final second = lexer.next();
      if (second.type == PdfTokenType.number) {
        final savedPos2 = lexer.pos;
        final third = lexer.next();
        if (third.type == PdfTokenType.keyword && third.text == 'R') {
          return PdfRef(token.number!.toInt(), second.number!.toInt());
        }
        lexer.pos = savedPos2;
      }
      lexer.pos = savedPos1;
      return PdfNumber(token.number!);
    case PdfTokenType.name:
      return PdfName(token.text!);
    case PdfTokenType.string:
      return PdfLiteralString(token.bytes!);
    case PdfTokenType.arrayStart:
      final items = <PdfObject>[];
      while (true) {
        final peek = lexer.next();
        if (peek.type == PdfTokenType.arrayEnd ||
            peek.type == PdfTokenType.eof) {
          break;
        }
        items.add(_parseValueFromToken(bytes, lexer, peek, resolveRef));
      }
      return PdfArrayObj(items);
    case PdfTokenType.dictStart:
      final entries = <String, PdfObject>{};
      while (true) {
        final keyTok = lexer.next();
        if (keyTok.type == PdfTokenType.dictEnd ||
            keyTok.type == PdfTokenType.eof) {
          break;
        }
        if (keyTok.type != PdfTokenType.name) continue;
        entries[keyTok.text!] = _parseValue(bytes, lexer, resolveRef);
      }
      final dict = PdfDictionaryObj(entries);
      final savedPos = lexer.pos;
      final maybeStream = lexer.next();
      if (maybeStream.type == PdfTokenType.keyword &&
          maybeStream.text == 'stream') {
        return _parseStreamBody(bytes, lexer, dict, resolveRef);
      }
      lexer.pos = savedPos;
      return dict;
    case PdfTokenType.keyword:
      if (token.text == 'true') return const PdfBool(true);
      if (token.text == 'false') return const PdfBool(false);
      return const PdfNull();
    default:
      return const PdfNull();
  }
}

PdfStreamObj _parseStreamBody(
  Uint8List bytes,
  PdfLexer lexer,
  PdfDictionaryObj dict,
  _RefResolver? resolveRef,
) {
  var p = lexer.pos;
  if (p < bytes.length && bytes[p] == 13) p++;
  if (p < bytes.length && bytes[p] == 10) p++;

  final lengthObj = dict['Length'];
  int? length;
  if (lengthObj is PdfNumber) {
    length = lengthObj.intValue;
  } else if (lengthObj is PdfRef && resolveRef != null) {
    final resolved = resolveRef(lengthObj);
    if (resolved is PdfNumber) length = resolved.intValue;
  }

  const endMarker = 'endstream';
  Uint8List raw;
  int afterStreamPos;
  if (length != null && p + length <= bytes.length) {
    var checkPos = p + length;
    while (checkPos < bytes.length &&
        (bytes[checkPos] == 13 ||
            bytes[checkPos] == 10 ||
            bytes[checkPos] == 32)) {
      checkPos++;
    }
    if (_matchesAscii(bytes, checkPos, endMarker)) {
      raw = bytes.sublist(p, p + length);
      afterStreamPos = checkPos + endMarker.length;
    } else {
      final found = _scanForEndstream(bytes, p);
      raw = bytes.sublist(p, found.dataEnd);
      afterStreamPos = found.afterMarker;
    }
  } else {
    final found = _scanForEndstream(bytes, p);
    raw = bytes.sublist(p, found.dataEnd);
    afterStreamPos = found.afterMarker;
  }
  lexer.pos = afterStreamPos;
  return PdfStreamObj(dict, raw);
}

bool _matchesAscii(Uint8List bytes, int offset, String text) {
  if (offset + text.length > bytes.length) return false;
  for (var i = 0; i < text.length; i++) {
    if (bytes[offset + i] != text.codeUnitAt(i)) return false;
  }
  return true;
}

({int dataEnd, int afterMarker}) _scanForEndstream(
  Uint8List bytes,
  int start,
) {
  const marker = 'endstream';
  for (var i = start; i <= bytes.length - marker.length; i++) {
    if (_matchesAscii(bytes, i, marker)) {
      var dataEnd = i;
      if (dataEnd > start && bytes[dataEnd - 1] == 10) dataEnd--;
      if (dataEnd > start && bytes[dataEnd - 1] == 13) dataEnd--;
      return (dataEnd: dataEnd, afterMarker: i + marker.length);
    }
  }
  return (dataEnd: bytes.length, afterMarker: bytes.length);
}

int? _findLastStartXref(Uint8List bytes) {
  const marker = 'startxref';
  for (var i = bytes.length - marker.length; i >= 0; i--) {
    if (_matchesAscii(bytes, i, marker)) {
      final lexer = PdfLexer(bytes, i + marker.length);
      final token = lexer.next();
      if (token.type == PdfTokenType.number) return token.number!.toInt();
    }
  }
  return null;
}

class _XrefSection {
  const _XrefSection(this.entries, this.trailer);
  final Map<int, _XrefEntry> entries;
  final PdfDictionaryObj trailer;
}

_XrefSection _parseXrefSection(Uint8List bytes, int offset) {
  final lexer = PdfLexer(bytes, offset);
  final savedPos = lexer.pos;
  final first = lexer.next();
  if (first.type == PdfTokenType.keyword && first.text == 'xref') {
    return _parseClassicXref(bytes, lexer);
  }
  lexer.pos = savedPos;
  return _parseXrefStream(bytes, lexer);
}

_XrefSection _parseClassicXref(Uint8List bytes, PdfLexer lexer) {
  final entries = <int, _XrefEntry>{};
  while (true) {
    final savedPos = lexer.pos;
    final startTok = lexer.next();
    if (startTok.type == PdfTokenType.keyword && startTok.text == 'trailer') {
      final trailerObj = _parseValue(bytes, lexer);
      final trailer = trailerObj is PdfDictionaryObj
          ? trailerObj
          : const PdfDictionaryObj({});
      return _XrefSection(entries, trailer);
    }
    if (startTok.type != PdfTokenType.number) {
      lexer.pos = savedPos;
      break;
    }
    final countTok = lexer.next();
    if (countTok.type != PdfTokenType.number) break;
    final start = startTok.number!.toInt();
    final count = countTok.number!.toInt();
    for (var i = 0; i < count; i++) {
      final offsetTok = lexer.next();
      // Generation token is intentionally unused: this reader doesn't
      // support multiple generations of the same object number.
      lexer.next();
      final typeTok = lexer.next();
      if (offsetTok.type != PdfTokenType.number) continue;
      final isFree = typeTok.text == 'f';
      if (!isFree) {
        entries.putIfAbsent(
          start + i,
          () => _XrefEntry.direct(offsetTok.number!.toInt()),
        );
      }
    }
  }
  return _XrefSection(entries, const PdfDictionaryObj({}));
}

_XrefSection _parseXrefStream(Uint8List bytes, PdfLexer lexer) {
  final numTok = lexer.next();
  final genTok = lexer.next();
  final objTok = lexer.next();
  if (numTok.type != PdfTokenType.number ||
      genTok.type != PdfTokenType.number ||
      objTok.type != PdfTokenType.keyword ||
      objTok.text != 'obj') {
    return _XrefSection({}, const PdfDictionaryObj({}));
  }
  final value = _parseValue(bytes, lexer);
  if (value is! PdfStreamObj) return _XrefSection({}, const PdfDictionaryObj({}));

  final dict = value.dict;
  final widthsObj = dict['W'];
  final widths = widthsObj is PdfArrayObj
      ? widthsObj.items.map((item) => (item as PdfNumber).intValue).toList()
      : <int>[1, 2, 1];
  final size = (dict['Size'] as PdfNumber?)?.intValue ?? 0;
  final indexObj = dict['Index'];
  final index = indexObj is PdfArrayObj
      ? indexObj.items.map((item) => (item as PdfNumber).intValue).toList()
      : [0, size];

  // Decoding the xref stream itself only ever needs Flate+predictor with
  // parameters given directly in its own dict (never indirect), so an
  // empty/bootstrap document is sufficient here.
  final bootstrapDoc = PdfDocument._(bytes, {}, const PdfDictionaryObj({}));
  final decoded = bootstrapDoc.decodeStream(value);

  final entries = <int, _XrefEntry>{};
  final w0 = widths.isNotEmpty ? widths[0] : 1;
  final w1 = widths.length > 1 ? widths[1] : 2;
  final w2 = widths.length > 2 ? widths[2] : 1;
  final recordSize = w0 + w1 + w2;
  if (recordSize <= 0) return _XrefSection(entries, dict);

  var pos = 0;
  for (var pairIndex = 0; pairIndex + 1 < index.length; pairIndex += 2) {
    final start = index[pairIndex];
    final count = index[pairIndex + 1];
    for (var i = 0; i < count; i++) {
      if (pos + recordSize > decoded.length) break;
      final type = w0 == 0 ? 1 : _readBigEndian(decoded, pos, w0);
      final field2 = _readBigEndian(decoded, pos + w0, w1);
      final field3 = _readBigEndian(decoded, pos + w0 + w1, w2);
      pos += recordSize;
      final objNum = start + i;
      switch (type) {
        case 1:
          entries.putIfAbsent(objNum, () => _XrefEntry.direct(field2));
        case 2:
          entries.putIfAbsent(
            objNum,
            () => _XrefEntry.compressed(field2, field3),
          );
        default:
          break; // type 0: free object
      }
    }
  }
  return _XrefSection(entries, dict);
}

int _readBigEndian(Uint8List bytes, int offset, int length) {
  var value = 0;
  for (var i = 0; i < length; i++) {
    value = (value << 8) | bytes[offset + i];
  }
  return value;
}

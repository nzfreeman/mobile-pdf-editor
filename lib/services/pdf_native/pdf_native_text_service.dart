import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'pdf_content_stream.dart';
import 'pdf_document.dart';
import 'pdf_incremental_writer.dart';
import 'pdf_native_edit_builder.dart';

class PdfNativePage {
  const PdfNativePage({required this.pageIndex, required this.runs});
  final int pageIndex;
  final List<PdfTextRun> runs;
}

/// Public entry point for the "read/edit real PDF text objects" feature:
/// wires the low-level parser, content-stream walker, font resolver, and
/// incremental writer together.
///
/// Scope, by design (see individual file docs for details): this only
/// understands FlateDecode-compressed, unencrypted PDFs with classic or
/// xref-stream cross-reference tables. Text using simple (WinAnsi-ish
/// single-byte) fonts can be both read and edited in place, preserving
/// the original font resource. Text using Type0/CID composite fonts
/// (which is how most Korean/CJK text is encoded) can be *read* whenever
/// the font has an embedded ToUnicode CMap, but cannot be *edited*
/// through this path — re-encoding new characters into a CID font
/// requires parsing the embedded font program's own cmap table, which
/// this implementation does not do. Callers should fall back to the
/// existing OCR-overlay edit flow for those runs.
class PdfNativeTextService {
  PdfNativeTextService._();

  static Future<List<PdfNativePage>> extractRuns(File file) async {
    final bytes = await file.readAsBytes();
    final doc = PdfDocument.parse(bytes);
    final pages = doc.pages;
    return [
      for (var i = 0; i < pages.length; i++)
        PdfNativePage(pageIndex: i, runs: extractTextRuns(doc, pages[i])),
    ];
  }

  static Future<File> replaceRunText({
    required File file,
    required PdfTextRun run,
    required String newText,
  }) async {
    final bytes = await file.readAsBytes();
    final doc = PdfDocument.parse(bytes);
    final replacementBytes = buildReplacementOperatorBytes(run, newText);
    final newBytes = applyIncrementalEdits(doc, bytes, [
      PdfEdit(
        streamRef: run.contentStreamRef,
        start: run.byteStartInStream,
        end: run.byteEndInStream,
        replacement: replacementBytes,
      ),
    ]);

    final directory = await getApplicationDocumentsDirectory();
    final output = File(
      '${directory.path}/native_edit_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await output.writeAsBytes(newBytes, flush: true);
    return output;
  }
}

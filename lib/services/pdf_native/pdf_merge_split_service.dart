import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'pdf_document.dart';
import 'pdf_form_fields.dart';
import 'pdf_object_copier.dart';
import 'pdf_objects.dart';

/// Structure-preserving merge/split: copies page (and everything a page
/// reaches — content streams, fonts, images, annotations/form fields)
/// object-for-object into a fresh document instead of rasterizing each
/// page to an image and rebuilding from pixels. This is what actually
/// keeps text searchable/selectable, vector graphics vector, and any
/// AcroForm fields on the affected pages still live — the raster
/// approach (still used by PdfService.compressPdf, where re-encoding
/// pixel data is the whole point) inherently can't preserve any of that.
class PdfMergeSplitService {
  PdfMergeSplitService._();

  static Future<File> merge({
    required List<File> files,
    required String outputName,
  }) async {
    final copier = PdfObjectCopier();
    final pageRefs = <int>[];
    final fieldRefs = <int>[];

    for (final file in files) {
      final bytes = await file.readAsBytes();
      final doc = PdfDocument.parse(bytes);
      for (final page in doc.pages) {
        pageRefs.add(copier.copyPage(doc, page));
      }
      for (final field in extractFormFields(doc)) {
        fieldRefs.add(copier.copyRef(doc, field.ref));
      }
    }

    final rootObjNum = _assembleCatalog(copier, pageRefs, fieldRefs);
    return _save(copier.write(rootObjNum: rootObjNum), outputName);
  }

  /// Splits [file] into one output PDF per group of (0-based) page
  /// indices in [pageGroups], preserving order.
  static Future<List<File>> split({
    required File file,
    required List<List<int>> pageGroups,
    required String sourceName,
  }) async {
    final bytes = await file.readAsBytes();
    final outputs = <File>[];

    for (var i = 0; i < pageGroups.length; i++) {
      // A fresh parse + fresh copier per output keeps each output file
      // fully independent (no accidental object sharing between them).
      final doc = PdfDocument.parse(bytes);
      final pages = doc.pages;
      final fields = extractFormFields(doc);
      final copier = PdfObjectCopier();

      final indices = pageGroups[i];
      final pageRefs = <int>[];
      for (final index in indices) {
        pageRefs.add(copier.copyPage(doc, pages[index]));
      }
      final fieldRefs = <int>[
        for (final field in fields)
          if (indices.contains(field.pageIndex)) copier.copyRef(doc, field.ref),
      ];

      final rootObjNum = _assembleCatalog(copier, pageRefs, fieldRefs);
      final baseName = sourceName.replaceAll(RegExp(r'\.[Pp][Dd][Ff]$'), '');
      outputs.add(
        await _save(copier.write(rootObjNum: rootObjNum), '${baseName}_part${i + 1}'),
      );
    }
    return outputs;
  }

  static int _assembleCatalog(
    PdfObjectCopier copier,
    List<int> pageRefs,
    List<int> fieldRefs,
  ) {
    final pagesObjNum = copier.allocateNew(const PdfNull());
    final pagesRef = PdfRef(pagesObjNum, 0);
    for (final pageObjNum in pageRefs) {
      copier.setParent(pageObjNum, pagesRef);
    }
    copier.replace(
      pagesObjNum,
      PdfDictionaryObj({
        'Type': const PdfName('Pages'),
        'Kids': PdfArrayObj(pageRefs.map((n) => PdfRef(n, 0)).toList()),
        'Count': PdfNumber(pageRefs.length),
      }),
    );

    final catalogEntries = <String, PdfObject>{
      'Type': const PdfName('Catalog'),
      'Pages': pagesRef,
    };
    if (fieldRefs.isNotEmpty) {
      catalogEntries['AcroForm'] = PdfDictionaryObj({
        'Fields': PdfArrayObj(fieldRefs.map((n) => PdfRef(n, 0)).toList()),
        'DA': PdfLiteralString(Uint8List.fromList(latin1.encode('/Helv 12 Tf 0 g'))),
        'NeedAppearances': const PdfBool(false),
      });
    }
    return copier.allocateNew(PdfDictionaryObj(catalogEntries));
  }

  static Future<File> _save(Uint8List bytes, String baseName) async {
    final directory = await getApplicationDocumentsDirectory();
    final safeName = baseName
        .replaceAll(RegExp(r'\.[Pp][Dd][Ff]$'), '')
        .replaceAll(RegExp(r'[^a-zA-Z0-9가-힣_-]'), '_');
    final output = File(
      '${directory.path}/${safeName}_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await output.writeAsBytes(bytes, flush: true);
    return output;
  }
}

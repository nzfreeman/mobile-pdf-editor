import 'dart:typed_data';

import 'package:flutter/material.dart';

enum EditorItemType {
  text,
  check,
  signature,
  image,
  stamp,
  drawing,
  rect,
  memo,
  link,
}

class DrawingPoint {
  const DrawingPoint(this.dx, this.dy);

  final double dx;
  final double dy;

  Offset toOffset(Size size) => Offset(dx * size.width, dy * size.height);
}

class EditorItem {
  EditorItem({
    required this.id,
    required this.type,
    required this.pageIndex,
    required this.x,
    required this.y,
    this.width = 0.25,
    this.height = 0.08,
    this.text,
    this.bytes,
    this.fontSize = 18,
    this.rotation = 0,
    this.points = const [],
    this.strokeWidth = 3,
    this.colorValue = 0xFF000000,
    this.linkUrl,
    this.linkTargetPage,
    this.bold = false,
    this.italic = false,
    this.textAlign = TextAlign.left,
  });

  final String id;
  final EditorItemType type;
  final int pageIndex;
  double x;
  double y;
  double width;
  double height;
  String? text;
  Uint8List? bytes;
  double fontSize;
  double rotation;
  List<DrawingPoint> points;
  double strokeWidth;
  int colorValue;

  /// Target URL for an external [EditorItemType.link] item. Exactly one
  /// of [linkUrl]/[linkTargetPage] is set for a given link.
  String? linkUrl;

  /// Target page index (0-based) for an internal same-document
  /// [EditorItemType.link] item.
  int? linkTargetPage;

  /// Styling for [EditorItemType.text]/[EditorItemType.memo] items.
  bool bold;
  bool italic;
  TextAlign textAlign;

  EditorItem copy() => copyWith();

  EditorItem copyWith({
    String? id,
    int? pageIndex,
    double? x,
    double? y,
    double? width,
    double? height,
    String? text,
    Uint8List? bytes,
    double? fontSize,
    double? rotation,
    List<DrawingPoint>? points,
    double? strokeWidth,
    int? colorValue,
    String? linkUrl,
    int? linkTargetPage,
    bool? bold,
    bool? italic,
    TextAlign? textAlign,
  }) {
    return EditorItem(
      id: id ?? this.id,
      type: type,
      pageIndex: pageIndex ?? this.pageIndex,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      text: text ?? this.text,
      bytes:
          bytes ??
          (this.bytes == null ? null : Uint8List.fromList(this.bytes!)),
      fontSize: fontSize ?? this.fontSize,
      rotation: rotation ?? this.rotation,
      points: points ?? List<DrawingPoint>.from(this.points),
      strokeWidth: strokeWidth ?? this.strokeWidth,
      colorValue: colorValue ?? this.colorValue,
      linkUrl: linkUrl ?? this.linkUrl,
      linkTargetPage: linkTargetPage ?? this.linkTargetPage,
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      textAlign: textAlign ?? this.textAlign,
    );
  }
}

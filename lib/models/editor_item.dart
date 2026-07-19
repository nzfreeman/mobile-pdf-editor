import 'dart:typed_data';
import 'package:flutter/material.dart';

enum EditorItemType { text, check, signature, image, stamp, drawing }

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

  EditorItem copy() => EditorItem(
        id: id,
        type: type,
        pageIndex: pageIndex,
        x: x,
        y: y,
        width: width,
        height: height,
        text: text,
        bytes: bytes == null ? null : Uint8List.fromList(bytes!),
        fontSize: fontSize,
        rotation: rotation,
        points: List<DrawingPoint>.from(points),
        strokeWidth: strokeWidth,
        colorValue: colorValue,
      );
}

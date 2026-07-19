from pathlib import Path

path = Path('lib/screens/pdf_editor_screen.dart')
text = path.read_text(encoding='utf-8')


def replace_once(old: str, new: str, label: str) -> None:
    global text
    if old not in text:
        raise SystemExit(f'Patch target not found: {label}')
    text = text.replace(old, new, 1)


replace_once(
    "  final _transformController = TransformationController();\n  final _picker = ImagePicker();",
    "  final _transformController = TransformationController();\n"
    "  final _objectToolbarController = ScrollController();\n"
    "  final _picker = ImagePicker();",
    'toolbar controller field',
)

replace_once(
    "  bool _drawingMode = false;\n  double _zoomScale = 1;\n  List<DrawingPoint> _activeStroke = [];",
    "  bool _drawingMode = false;\n"
    "  bool _showMoreToolsIndicator = true;\n"
    "  bool _resizingItem = false;\n"
    "  bool _rotatingItem = false;\n"
    "  double _zoomScale = 1;\n"
    "  List<DrawingPoint> _activeStroke = [];",
    'editor interaction state',
)

replace_once(
    "  void initState() {\n    super.initState();\n    _load();\n  }",
    "  void initState() {\n"
    "    super.initState();\n"
    "    _objectToolbarController.addListener(_updateToolbarIndicator);\n"
    "    _load();\n"
    "  }",
    'init state listener',
)

replace_once(
    "    _pageController.dispose();\n    _transformController.dispose();\n    super.dispose();",
    "    _pageController.dispose();\n"
    "    _transformController.dispose();\n"
    "    _objectToolbarController.dispose();\n"
    "    super.dispose();",
    'dispose toolbar controller',
)

replace_once(
    "  void _resetView() {\n"
    "    _transformController.value = Matrix4.identity();\n"
    "    if (_zoomScale != 1) setState(() => _zoomScale = 1);\n"
    "  }",
    "  void _resetView() {\n"
    "    _transformController.value = Matrix4.identity();\n"
    "    if (_zoomScale != 1) setState(() => _zoomScale = 1);\n"
    "  }\n\n"
    "  void _toggleZoom() {\n"
    "    if (_zoomScale > 1.05) {\n"
    "      _resetView();\n"
    "      return;\n"
    "    }\n"
    "    _transformController.value = Matrix4.identity()..scale(2.0);\n"
    "    setState(() => _zoomScale = 2.0);\n"
    "  }\n\n"
    "  void _updateToolbarIndicator() {\n"
    "    if (!_objectToolbarController.hasClients) return;\n"
    "    final position = _objectToolbarController.position;\n"
    "    final show = position.maxScrollExtent > 8 &&\n"
    "        position.pixels < position.maxScrollExtent - 8;\n"
    "    if (show != _showMoreToolsIndicator && mounted) {\n"
    "      setState(() => _showMoreToolsIndicator = show);\n"
    "    }\n"
    "  }\n\n"
    "  void _scrollObjectToolbarForward() {\n"
    "    if (!_objectToolbarController.hasClients) return;\n"
    "    final position = _objectToolbarController.position;\n"
    "    _objectToolbarController.animateTo(\n"
    "      math.min(position.pixels + 230, position.maxScrollExtent),\n"
    "      duration: const Duration(milliseconds: 260),\n"
    "      curve: Curves.easeOut,\n"
    "    );\n"
    "  }",
    'zoom and toolbar helpers',
)

start = text.index('  Widget _buildObjectToolbar() {')
end = text.index('  Widget _buildThumbnails() {', start)
new_toolbar = r'''  Widget _buildObjectToolbar() {
    final selected = _selectedItem;
    final supportsColor = selected == null ||
        selected.type == EditorItemType.text ||
        selected.type == EditorItemType.check ||
        selected.type == EditorItemType.drawing;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateToolbarIndicator();
    });

    return Material(
      elevation: 6,
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: SizedBox(
          height: 72,
          child: Stack(
            children: [
              ListView(
                controller: _objectToolbarController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(10, 8, 72, 8),
                children: [
                  if (supportsColor)
                    ..._palette.map(
                      (color) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InkWell(
                          onTap: selected == null
                              ? null
                              : () => _setSelectedColor(color),
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selected?.colorValue == color.toARGB32()
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.white,
                                width: 3,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x33000000),
                                  blurRadius: 2,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (selected != null) ...[
                    const VerticalDivider(),
                    _toolbarAction(
                      icon: Icons.remove,
                      label: '작게',
                      onTap: () => _changeSelectedSize(0.9),
                    ),
                    _toolbarAction(
                      icon: Icons.add,
                      label: '크게',
                      onTap: () => _changeSelectedSize(1.1),
                    ),
                    _toolbarAction(
                      icon: Icons.rotate_left,
                      label: '왼쪽',
                      onTap: () => _rotateSelected(-math.pi / 12),
                    ),
                    _toolbarAction(
                      icon: Icons.rotate_right,
                      label: '오른쪽',
                      onTap: () => _rotateSelected(math.pi / 12),
                    ),
                    _toolbarAction(
                      icon: Icons.control_point_duplicate,
                      label: '복제',
                      onTap: _duplicateSelected,
                    ),
                    if (selected.type == EditorItemType.text)
                      _toolbarAction(
                        icon: Icons.edit,
                        label: '수정',
                        onTap: () => _editText(selected),
                      ),
                    _toolbarAction(
                      icon: Icons.delete_outline,
                      label: '삭제',
                      onTap: _deleteSelected,
                      danger: true,
                    ),
                  ],
                ],
              ),
              if (_showMoreToolsIndicator)
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 70,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Theme.of(context)
                              .colorScheme
                              .surface
                              .withValues(alpha: 0),
                          Theme.of(context).colorScheme.surface,
                          Theme.of(context).colorScheme.surface,
                        ],
                      ),
                    ),
                    child: InkWell(
                      onTap: _scrollObjectToolbarForward,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chevron_right,
                            color: Theme.of(context).colorScheme.primary,
                            size: 28,
                          ),
                          Text(
                            '더보기',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbarAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final color = danger
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 58,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 10, color: color)),
          ],
        ),
      ),
    );
  }

'''
text = text[:start] + new_toolbar + text[end:]

start = text.index('  Widget _buildPage(int index) {')
end = text.index('  Widget _itemWidget(EditorItem item, Size pageSize) {', start)
new_page = r'''  Widget _buildPage(int index) {
    final page = _pages[index];
    return LayoutBuilder(
      builder: (context, constraints) {
        const margin = 10.0;
        final availableWidth = math.max(1.0, constraints.maxWidth - margin * 2);
        final availableHeight = math.max(1.0, constraints.maxHeight - margin * 2);
        var pageWidth = availableWidth;
        var pageHeight = pageWidth / page.aspectRatio;
        if (pageHeight > availableHeight) {
          pageHeight = availableHeight;
          pageWidth = pageHeight * page.aspectRatio;
        }
        final pageSize = Size(pageWidth, pageHeight);
        final pageItems = _items.where((item) => item.pageIndex == index).toList();

        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _transformController,
                constrained: true,
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                boundaryMargin: const EdgeInsets.all(300),
                minScale: 1,
                maxScale: 6,
                panEnabled: !_drawingMode,
                scaleEnabled: !_drawingMode,
                onInteractionUpdate: (_) {
                  final scale = _transformController.value.getMaxScaleOnAxis();
                  if ((scale - _zoomScale).abs() > 0.02) {
                    setState(() => _zoomScale = scale);
                  }
                },
                onInteractionEnd: (_) {
                  final scale = _transformController.value.getMaxScaleOnAxis();
                  if ((scale - _zoomScale).abs() > 0.005) {
                    setState(() => _zoomScale = scale);
                  }
                },
                child: Center(
                  child: SizedBox(
                    width: pageWidth,
                    height: pageHeight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        if (!_drawingMode) setState(() => _selectedId = null);
                      },
                      onDoubleTap: _drawingMode ? null : _toggleZoom,
                      onPanStart: (details) => _startStroke(details, pageSize),
                      onPanUpdate: (details) => _updateStroke(details, pageSize),
                      onPanEnd: _endStroke,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                boxShadow: [
                                  BoxShadow(
                                    blurRadius: 8,
                                    color: Color(0x33000000),
                                  ),
                                ],
                              ),
                              child: Image.memory(page.bytes, fit: BoxFit.fill),
                            ),
                          ),
                          ...pageItems.map((item) => _itemWidget(item, pageSize)),
                          if (_activeStroke.isNotEmpty)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _StrokePainter(
                                    _activeStroke,
                                    Colors.black,
                                    3,
                                  ),
                                ),
                              ),
                            ),
                          if (_drawingMode)
                            const Positioned(
                              top: 8,
                              left: 8,
                              child: Chip(label: Text('필기 모드')),
                            ),
                          if (_exporting)
                            const Positioned.fill(
                              child: ColoredBox(
                                color: Color(0x33000000),
                                child: Center(child: CircularProgressIndicator()),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 10,
              child: Material(
                color: Theme.of(context).colorScheme.inverseSurface.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  onTap: _resetView,
                  borderRadius: BorderRadius.circular(18),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    child: Text(
                      '${(_zoomScale * 100).round()}%',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onInverseSurface,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

'''
text = text[:start] + new_page + text[end:]

start = text.index('  Widget _itemWidget(EditorItem item, Size pageSize) {')
end = text.index('class _StrokePainter extends CustomPainter {', start)
new_item_and_handle = r'''  Widget _itemWidget(EditorItem item, Size pageSize) {
    final selected = _selectedId == item.id;
    final itemWidth = item.width * pageSize.width;
    final itemHeight = item.height * pageSize.height;

    final Widget content;
    if (item.type == EditorItemType.text) {
      content = Align(
        alignment: Alignment.topLeft,
        child: Text(
          item.text ?? '',
          style: TextStyle(
            fontSize: item.fontSize,
            color: Color(item.colorValue),
          ),
        ),
      );
    } else if (item.type == EditorItemType.check) {
      content = FittedBox(
        child: Text('✓', style: TextStyle(color: Color(item.colorValue))),
      );
    } else if (item.type == EditorItemType.drawing) {
      content = CustomPaint(
        painter: _StrokePainter(
          item.points,
          Color(item.colorValue),
          item.strokeWidth,
        ),
      );
    } else {
      content = item.bytes == null
          ? const SizedBox()
          : Image.memory(item.bytes!, fit: BoxFit.contain);
    }

    return Positioned(
      left: item.x * pageSize.width,
      top: item.y * pageSize.height,
      width: itemWidth,
      height: itemHeight,
      child: Transform.rotate(
        angle: item.rotation,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (!_drawingMode) {
                    setState(() {
                      _selectedId = item.id;
                      _showMoreToolsIndicator = true;
                    });
                    if (_objectToolbarController.hasClients) {
                      _objectToolbarController.jumpTo(0);
                    }
                  }
                },
                onDoubleTap: item.type == EditorItemType.text
                    ? () => _editText(item)
                    : null,
                onPanStart: (_) {
                  if (_drawingMode) return;
                  _commit();
                  setState(() => _selectedId = item.id);
                },
                onPanUpdate: (details) {
                  if (_drawingMode) return;
                  setState(() {
                    item.x = (item.x + details.delta.dx / pageSize.width)
                        .clamp(0.0, 1.0 - item.width)
                        .toDouble();
                    item.y = (item.y + details.delta.dy / pageSize.height)
                        .clamp(0.0, 1.0 - item.height)
                        .toDouble();
                  });
                },
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: selected
                        ? Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2.5,
                          )
                        : null,
                  ),
                  child: Padding(
                    padding: selected
                        ? const EdgeInsets.all(2)
                        : EdgeInsets.zero,
                    child: content,
                  ),
                ),
              ),
            ),
            if (selected) ...[
              Positioned(
                top: -58,
                left: 0,
                right: 0,
                child: Center(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) {
                      _commit();
                      setState(() => _rotatingItem = true);
                    },
                    onPanUpdate: (details) {
                      setState(() => item.rotation += details.delta.dx * 0.018);
                    },
                    onPanEnd: (_) => setState(() => _rotatingItem = false),
                    onPanCancel: () => setState(() => _rotatingItem = false),
                    child: _handle(
                      icon: Icons.rotate_right,
                      tooltip: '좌우로 드래그하여 회전',
                      active: _rotatingItem,
                    ),
                  ),
                ),
              ),
              Positioned(
                right: -25,
                bottom: -25,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) {
                    _commit();
                    setState(() => _resizingItem = true);
                  },
                  onPanUpdate: (details) {
                    setState(() {
                      final oldWidth = item.width;
                      final nextWidth =
                          (item.width + details.delta.dx / pageSize.width)
                              .clamp(0.045, 1.0 - item.x)
                              .toDouble();
                      final nextHeight =
                          (item.height + details.delta.dy / pageSize.height)
                              .clamp(0.035, 1.0 - item.y)
                              .toDouble();
                      item.width = nextWidth;
                      item.height = nextHeight;
                      if (item.type == EditorItemType.text && oldWidth > 0) {
                        item.fontSize = (item.fontSize * nextWidth / oldWidth)
                            .clamp(8.0, 96.0)
                            .toDouble();
                      }
                    });
                  },
                  onPanEnd: (_) => setState(() => _resizingItem = false),
                  onPanCancel: () => setState(() => _resizingItem = false),
                  child: _handle(
                    icon: Icons.open_in_full,
                    tooltip: '드래그하여 크기 조절',
                    active: _resizingItem,
                  ),
                ),
              ),
              Positioned(
                left: -25,
                top: -25,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _deleteSelected,
                  child: _handle(
                    icon: Icons.close,
                    tooltip: '삭제',
                    danger: true,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _handle({
    required IconData icon,
    required String tooltip,
    bool danger = false,
    bool active = false,
  }) {
    final baseColor = danger
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 52,
        height: 52,
        alignment: Alignment.center,
        decoration: const BoxDecoration(shape: BoxShape.circle),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: active ? 46 : 42,
          height: active ? 46 : 42,
          decoration: BoxDecoration(
            color: active ? baseColor.withValues(alpha: 0.82) : baseColor,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: active ? 3 : 2),
            boxShadow: [
              BoxShadow(
                blurRadius: active ? 8 : 4,
                spreadRadius: active ? 2 : 0,
                color: const Color(0x66000000),
              ),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: active ? 25 : 22),
        ),
      ),
    );
  }
}

'''
text = text[:start] + new_item_and_handle + text[end:]

path.write_text(text, encoding='utf-8')
print('Editor UX patch applied successfully.')

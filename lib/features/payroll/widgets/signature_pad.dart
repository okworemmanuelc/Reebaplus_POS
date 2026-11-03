import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Holds the strokes of one [SignaturePad] (#671) and turns them into a PNG.
///
/// Written here rather than pulled from a package: a signature is a few
/// strokes on a canvas, and keeping it in-house adds no dependency.
class SignaturePadController extends ChangeNotifier {
  final List<List<Offset>> _strokes = [];
  Size _size = Size.zero;

  /// The strokes so far (each a list of points in the pad's coordinates).
  List<List<Offset>> get strokes => List.unmodifiable(_strokes);

  /// True until something has been drawn.
  bool get isEmpty => _strokes.every((s) => s.isEmpty);

  void _start(Offset p) {
    _strokes.add([p]);
    notifyListeners();
  }

  void _extend(Offset p) {
    if (_strokes.isEmpty) return;
    _strokes.last.add(p);
    notifyListeners();
  }

  /// Wipes the pad.
  void clear() {
    _strokes.clear();
    notifyListeners();
  }

  /// The signature as a base64 PNG (black ink on white), or null when empty.
  Future<String?> toPngBase64() async {
    if (isEmpty) return null;
    final size = _size == Size.zero ? const Size(320, 140) : _size;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    paintSignatureStrokes(canvas, _strokes, Colors.black);
    final image = await recorder.endRecording().toImage(
      size.width.ceil(),
      size.height.ceil(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) return null;
    return base64Encode(bytes.buffer.asUint8List());
  }
}

/// Draws [strokes] with a round pen.
void paintSignatureStrokes(
  Canvas canvas,
  List<List<Offset>> strokes,
  Color color,
) {
  final pen = Paint()
    ..color = color
    ..strokeWidth = 2.5
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;
  for (final s in strokes) {
    if (s.isEmpty) continue;
    if (s.length == 1) {
      canvas.drawCircle(s.first, 1.5, pen..style = PaintingStyle.fill);
      pen.style = PaintingStyle.stroke;
      continue;
    }
    final path = Path()..moveTo(s.first.dx, s.first.dy);
    for (final p in s.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, pen);
  }
}

/// A box to sign in with a finger. Claims the drag at once, so signing never
/// scrolls the page around it.
class SignaturePad extends StatefulWidget {
  const SignaturePad({
    super.key,
    required this.controller,
    required this.label,
    this.height = 140,
  });

  final SignaturePadController controller;
  final String label;
  final double height;

  @override
  State<SignaturePad> createState() => _SignaturePadState();
}

class _SignaturePadState extends State<SignaturePad> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(SignaturePad old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.label,
                style: t.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TextButton(
              onPressed: c.isEmpty ? null : c.clear,
              child: const Text('Clear'),
            ),
          ],
        ),
        LayoutBuilder(
          builder: (context, box) {
            c._size = Size(box.maxWidth, widget.height);
            return RawGestureDetector(
              gestures: {
                _EagerPanRecognizer:
                    GestureRecognizerFactoryWithHandlers<_EagerPanRecognizer>(
                      _EagerPanRecognizer.new,
                      (r) => r
                        ..onStart = ((d) => c._start(d.localPosition))
                        ..onUpdate = ((d) => c._extend(d.localPosition)),
                    ),
              },
              child: Container(
                height: widget.height,
                decoration: BoxDecoration(
                  // Paper-white whatever the theme, so the ink reads.
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: t.colorScheme.outline),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CustomPaint(
                    painter: _StrokesPainter(c.strokes),
                    child: c.isEmpty
                        ? Center(
                            child: Text(
                              'Sign here',
                              style: TextStyle(
                                color: Colors.black.withValues(alpha: 0.35),
                              ),
                            ),
                          )
                        : const SizedBox.expand(),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// A pan recognizer that wins the gesture arena on touch-down.
class _EagerPanRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _StrokesPainter extends CustomPainter {
  _StrokesPainter(this.strokes);

  final List<List<Offset>> strokes;

  @override
  void paint(Canvas canvas, Size size) =>
      paintSignatureStrokes(canvas, strokes, Colors.black);

  @override
  bool shouldRepaint(_StrokesPainter old) => true;
}

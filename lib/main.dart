import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  runApp(const VastuApp());
}

class VastuApp extends StatelessWidget {
  const VastuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Vastu Plot Chakra',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const HomePage(),
    );
  }
}

class ChakraTransform {
  Offset offset = Offset.zero;
  double scale = 1.0;
  double angle = 0.0;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ImagePicker picker = ImagePicker();
  final List<Offset> points = [];
  final List<Uint8List> chakras = [];
  final List<ChakraTransform> transforms = [];

  Uint8List? plotBytes;
  String? chakraFolder;
  int selectedChakra = 0;
  bool closed = false;
  bool deleteMode = false;

  final clientName = TextEditingController();
  final address = TextEditingController();
  final mobile = TextEditingController();
  final degree = TextEditingController(text: '0');

  ChakraTransform get transform => transforms[selectedChakra];

  Future<void> pickPlot() async {
    final x = await picker.pickImage(source: ImageSource.gallery);
    if (x == null) return;
    setState(() => plotBytes = File(x.path).readAsBytesSync());
  }

  Future<void> chooseFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select CHKRA folder',
    );
    if (dir == null) return;
    chakraFolder = dir;
    await loadChakras();
  }

  Future<void> loadChakras() async {
    if (chakraFolder == null) return;
    final directory = Directory(chakraFolder!);
    if (!directory.existsSync()) return;

    final list = <File>[];
    for (final entity in directory.listSync()) {
      if (entity is File) {
        final ext = p.extension(entity.path).toLowerCase();
        if (['.png', '.jpg', '.jpeg', '.webp'].contains(ext)) {
          list.add(entity);
        }
      }
    }
    list.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    final loaded = <Uint8List>[];
    for (final file in list) {
      loaded.add(await file.readAsBytes());
    }

    setState(() {
      chakras
        ..clear()
        ..addAll(loaded);
      transforms
        ..clear()
        ..addAll(List.generate(chakras.length, (_) => ChakraTransform()));
      selectedChakra = 0;
      _applyDegreeToAll();
    });
  }

  void _applyDegreeToAll() {
    final d = double.tryParse(degree.text) ?? 0;
    for (final t in transforms) {
      t.angle = d * math.pi / 180.0;
    }
  }

  void setDegree(String value) {
    final d = double.tryParse(value) ?? 0;
    if (transforms.isEmpty) return;
    setState(() {
      for (final t in transforms) {
        t.angle = d * math.pi / 180.0;
      }
    });
  }

  void addPoint(Offset p) {
    if (closed) return;
    setState(() => points.add(p));
  }

  void movePoint(int index, Offset p) {
    setState(() => points[index] = p);
  }

  void undoPoint() {
    if (points.isEmpty || closed) return;
    setState(() => points.removeLast());
  }

  void deleteNearest(Offset p) {
    if (points.isEmpty) return;
    var best = 0;
    var distance = (points.first - p).distance;
    for (var i = 1; i < points.length; i++) {
      final d = (points[i] - p).distance;
      if (d < distance) {
        distance = d;
        best = i;
      }
    }
    if (distance < 45) {
      setState(() => points.removeAt(best));
    }
  }

  void toggleClosed() {
    if (points.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('कम से कम 3 points चाहिए।')),
      );
      return;
    }
    setState(() => closed = !closed);
  }

  void resetPolygon() {
    setState(() {
      points.clear();
      closed = false;
    });
  }

  void resetSelectedChakra() {
    if (transforms.isEmpty) return;
    setState(() {
      transform.offset = Offset.zero;
      transform.scale = 1;
      final d = double.tryParse(degree.text) ?? 0;
      transform.angle = d * math.pi / 180;
    });
  }

  Future<Uint8List?> _flattenChakra(Uint8List plot, Uint8List chakra) async {
    // PDF uses a single plot image + chakra overlay composition.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final plotImage = await _decode(plot);
    final chakraImage = await _decode(chakra);

    final size = Size(plotImage.width.toDouble(), plotImage.height.toDouble());
    canvas.drawImageRect(
      plotImage,
      Rect.fromLTWH(0, 0, plotImage.width.toDouble(), plotImage.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint(),
    );

    final t = transform;
    canvas.save();
    canvas.translate(
      size.width / 2 + t.offset.dx,
      size.height / 2 + t.offset.dy,
    );
    canvas.rotate(t.angle);
    canvas.scale(t.scale);
    final side = math.min(size.width, size.height) * 0.70;
    canvas.drawImageRect(
      chakraImage,
      Rect.fromLTWH(
        0,
        0,
        chakraImage.width.toDouble(),
        chakraImage.height.toDouble(),
      ),
      Rect.fromLTWH(-side / 2, -side / 2, side, side),
      Paint()..filterQuality = FilterQuality.high,
    );
    canvas.restore();

    final picture = recorder.endRecording();
    final image = await picture.toImage(plotImage.width, plotImage.height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  Future<void> makePdf() async {
    if (plotBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('पहले plot photo चुनें।')),
      );
      return;
    }
    final doc = pw.Document();

    final plotImage = pw.MemoryImage(plotBytes!);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('Vastu Plot Chakra Report',
                style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 10),
            pw.Text('Client: ${clientName.text}'),
            pw.Text('Address: ${address.text}'),
            pw.Text('Mobile: ${mobile.text}'),
            pw.Text('Plot Degree: ${degree.text}°'),
            pw.SizedBox(height: 12),
            pw.Expanded(child: pw.Image(plotImage, fit: pw.BoxFit.contain)),
            pw.SizedBox(height: 8),
            pw.Align(
              alignment: pw.Alignment.center,
              child: pw.Text('Ghanshyam Lohani'),
            ),
          ],
        ),
      ),
    );

    for (var i = 0; i < chakras.length; i++) {
      final savedIndex = i;
      final composition = await _flattenChakra(plotBytes!, chakras[savedIndex]);
      if (composition == null) continue;
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (_) => pw.Column(
            children: [
              pw.Expanded(
                child: pw.Image(
                  pw.MemoryImage(composition),
                  fit: pw.BoxFit.contain,
                ),
              ),
              pw.Text(
                'Chakra ${savedIndex + 1}  |  Plot Degree: ${degree.text}°',
              ),
              pw.SizedBox(height: 6),
              pw.Text('Ghanshyam Lohani'),
            ],
          ),
        ),
      );
    }

    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'Vastu_Plot_Chakra_Report.pdf'));
    await file.writeAsBytes(await doc.save());

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('PDF तैयार है: ${file.path}')),
    );
  }

  Widget buildPlotEditor() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = math.min(constraints.maxHeight, 430.0);
        return GestureDetector(
          onTapUp: (details) {
            if (deleteMode) {
              deleteNearest(details.localPosition);
            } else {
              addPoint(details.localPosition);
            }
          },
          child: Container(
            width: w,
            height: h,
            color: Colors.black12,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (plotBytes != null)
                  Image.memory(plotBytes!, fit: BoxFit.contain)
                else
                  const Center(child: Text('Plot photo upload करें')),
                CustomPaint(
                  painter: PolygonPainter(points, closed),
                ),
                for (var i = 0; i < points.length; i++)
                  Positioned(
                    left: points[i].dx - 17,
                    top: points[i].dy - 17,
                    child: GestureDetector(
                      onPanUpdate: (details) {
                        if (!deleteMode && !closed) {
                          movePoint(
                            i,
                            points[i] + details.delta,
                          );
                        }
                      },
                      child: Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '${i + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget buildChakraPreview() {
    if (plotBytes == null || chakras.isEmpty) {
      return const SizedBox(
        height: 240,
        child: Center(child: Text('Plot और CHKRA images चुनें')),
      );
    }
    return SizedBox(
      height: 420,
      child: LayoutBuilder(
        builder: (context, c) {
          return ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(plotBytes!, fit: BoxFit.contain),
                IgnorePointer(
                  child: CustomPaint(
                    painter: PolygonPainter(points, closed),
                  ),
                ),
                Center(
                  child: GestureDetector(
                    onScaleStart: (details) {
                      // Gesture values are finalized in onScaleUpdate.
                    },
                    onScaleUpdate: (details) {
                      setState(() {
                        transform.scale =
                            (transform.scale * details.scale).clamp(0.25, 4.0);
                        transform.offset += details.focalPointDelta;
                        if (details.rotation.abs() > 0.0001) {
                          transform.angle += details.rotation;
                        }
                      });
                    },
                    child: Transform.translate(
                      offset: transform.offset,
                      child: Transform.rotate(
                        angle: transform.angle,
                        child: Transform.scale(
                          scale: transform.scale,
                          child: Opacity(
                            opacity: 0.78,
                            child: Image.memory(
                              chakras[selectedChakra],
                              width: math.min(c.maxWidth, c.maxHeight) * 0.70,
                              height: math.min(c.maxWidth, c.maxHeight) * 0.70,
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vastu Plot + Chakra'),
        actions: [
          IconButton(
            onPressed: makePdf,
            tooltip: 'PDF',
            icon: const Icon(Icons.picture_as_pdf),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: pickPlot,
                  icon: const Icon(Icons.photo),
                  label: const Text('Plot Photo'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: chooseFolder,
                  icon: const Icon(Icons.folder),
                  label: const Text('CHKRA Folder'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: clientName,
            decoration: const InputDecoration(
              labelText: 'Client Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: address,
            decoration: const InputDecoration(
              labelText: 'Address',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: mobile,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Mobile',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: degree,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: setDegree,
            decoration: const InputDecoration(
              labelText: 'Plot Degree',
              suffixText: '°',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'IRREGULAR PLOT — Unlimited Points',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              OutlinedButton.icon(
                onPressed: undoPoint,
                icon: const Icon(Icons.undo),
                label: const Text('Undo'),
              ),
              OutlinedButton.icon(
                onPressed: toggleClosed,
                icon: Icon(closed ? Icons.lock_open : Icons.check),
                label: Text(closed ? 'Reopen' : 'Close Boundary'),
              ),
              OutlinedButton.icon(
                onPressed: resetPolygon,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Clear'),
              ),
              FilterChip(
                selected: deleteMode,
                onSelected: (v) => setState(() => deleteMode = v),
                label: const Text('Delete Point'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Points: ${points.length}'),
          const SizedBox(height: 8),
          buildPlotEditor(),
          const SizedBox(height: 12),
          if (chakras.isNotEmpty)
            DropdownButton<int>(
              value: selectedChakra,
              items: List.generate(
                chakras.length,
                (i) => DropdownMenuItem(
                  value: i,
                  child: Text('Chakra ${i + 1}'),
                ),
              ),
              onChanged: (v) {
                if (v != null) setState(() => selectedChakra = v);
              },
            ),
          if (chakras.isNotEmpty) ...[
            buildChakraPreview(),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: resetSelectedChakra,
                    child: const Text('Reset Chakra'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: makePdf,
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('Create PDF'),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'CHKRA folder: ${chakraFolder ?? 'Not selected'}',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          const Text(
            'PDF: हर Chakra अलग page पर उसी plot photo के ऊपर overlay होकर आएगा।',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

class PolygonPainter extends CustomPainter {
  final List<Offset> points;
  final bool closed;

  PolygonPainter(this.points, this.closed);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.red;

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    if (closed && points.length >= 3) {
      path.close();
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant PolygonPainter oldDelegate) => true;
}

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

const MethodChannel chakraChannel = MethodChannel(
  'com.graphicpoint.vastu_plot_chakra_pdf/chakra',
);

void main() => runApp(const VastuApp());

class VastuApp extends StatelessWidget {
  const VastuApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Vastu Plot + Chakra',
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2f6b3a)),
        ),
        home: const HomePage(),
      );
}

class BoundaryPoint {
  BoundaryPoint(this.position);
  Offset position;
}

class ChakraImage {
  ChakraImage({required this.name, required this.uri, required this.bytes});
  final String name;
  final String uri;
  final Uint8List bytes;
}

enum BoundaryMode { add, move, delete }

class ChakraTransform {
  ChakraTransform({
    this.angle = 0,
    this.scale = .84,
    this.center = const Offset(.5, .5),
    this.opacity = .78,
  });
  double angle;
  double scale;
  Offset center;
  double opacity;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ImagePicker picker = ImagePicker();
  final TextEditingController name = TextEditingController();
  final TextEditingController address = TextEditingController();
  final TextEditingController mobile = TextEditingController();
  final TextEditingController degree = TextEditingController(text: '0');
  final List<BoundaryPoint> points = <BoundaryPoint>[];
  final List<ChakraImage> chakras = <ChakraImage>[];
  final List<ChakraTransform> transforms = <ChakraTransform>[];
  File? plot;
  String? folderName;
  BoundaryMode boundaryMode = BoundaryMode.add;
  int selectedPoint = -1;
  bool loadingChakras = false;
  double plotDegree = 0;
  int tab = 0;

  @override
  void dispose() {
    name.dispose();
    address.dispose();
    mobile.dispose();
    degree.dispose();
    super.dispose();
  }

  double normalize(double value) {
    final double r = value % 360;
    return r < 0 ? r + 360 : r;
  }

  void msg(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> pickPlot() async {
    final XFile? x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 95);
    if (x == null || !mounted) return;
    setState(() {
      plot = File(x.path);
      selectedPoint = -1;
      boundaryMode = BoundaryMode.add;
      _setAutomaticCornerPoints();
      for (final ChakraTransform t in transforms) {
        t.center = const Offset(.5, .5);
      }
    });
  }

  void _setAutomaticCornerPoints() {
    points.clear();
    selectedPoint = -1;
  }

  Future<void> chooseFolder() async {
    await _loadChakras(pickFolder: true);
  }

  Future<void> refreshChakras() async {
    await _loadChakras(pickFolder: false);
  }

  Future<void> _loadChakras({required bool pickFolder}) async {
    try {
      setState(() => loadingChakras = true);
      final List<ChakraImage> found = await _pickOrRefreshChakraFolder(pickFolder: pickFolder);
      if (!mounted) return;
      setState(() {
        chakras
          ..clear()
          ..addAll(found);
        _syncTransforms();
      });
      msg(found.isEmpty ? 'CHKRA folder में supported image नहीं मिली।' : '${found.length} Chakra images मिलीं।');
    } on PlatformException catch (e) {
      msg(e.code == 'NO_FOLDER' ? 'पहले CHKRA Folder Select करें।' : 'CHKRA error: ${e.message ?? e.code}');
    } catch (e) {
      msg('CHKRA error: $e');
    } finally {
      if (mounted) setState(() => loadingChakras = false);
    }
  }

  Future<List<ChakraImage>> _pickOrRefreshChakraFolder({required bool pickFolder}) async {
    final dynamic raw = await chakraChannel.invokeMethod<dynamic>(pickFolder ? 'pickChakraFolder' : 'refreshChakraFolder');
    final List<dynamic> rows = raw is List<dynamic> ? raw : <dynamic>[];
    final List<ChakraImage> result = <ChakraImage>[];
    for (final dynamic row in rows) {
      if (row is! Map) continue;
      final String? uri = row['uri']?.toString();
      final String? imageName = row['name']?.toString();
      if (uri == null || imageName == null) continue;
      try {
        final Uint8List? bytes = await chakraChannel.invokeMethod<Uint8List>('readChakraImage', <String, dynamic>{'uri': uri});
        if (bytes != null && bytes.isNotEmpty) result.add(ChakraImage(name: imageName, uri: uri, bytes: bytes));
      } on PlatformException {
        // Skip unreadable images.
      }
    }
    result.sort((ChakraImage a, ChakraImage b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final String? selectedName = await chakraChannel.invokeMethod<String>('getChakraFolderName');
    if (mounted && selectedName != null && selectedName.isNotEmpty) setState(() => folderName = selectedName);
    return result;
  }

  Offset polygonCentroid() {
    if (points.isEmpty) return const Offset(.5, .5);
    if (points.length < 3) {
      double x = 0;
      double y = 0;
      for (final BoundaryPoint p in points) {
        x += p.position.dx;
        y += p.position.dy;
      }
      return Offset(x / points.length, y / points.length);
    }
    double area2 = 0;
    double cx = 0;
    double cy = 0;
    for (int i = 0; i < points.length; i++) {
      final Offset a = points[i].position;
      final Offset b = points[(i + 1) % points.length].position;
      final double cross = a.dx * b.dy - b.dx * a.dy;
      area2 += cross;
      cx += (a.dx + b.dx) * cross;
      cy += (a.dy + b.dy) * cross;
    }
    if (area2.abs() < 1e-9) return const Offset(.5, .5);
    return Offset(cx / (3 * area2), cy / (3 * area2));
  }

  void _syncTransforms() {
    final Offset center = polygonCentroid();
    while (transforms.length < chakras.length) transforms.add(ChakraTransform(angle: plotDegree, center: center));
    if (transforms.length > chakras.length) transforms.removeRange(chakras.length, transforms.length);
  }

  void setDegree(String value) {
    final double? n = double.tryParse(value);
    if (n == null) return;
    setState(() {
      plotDegree = normalize(n);
      for (final ChakraTransform t in transforms) t.angle = plotDegree;
    });
  }

  void updatePoint(int index, Offset position) {
    if (index < 0 || index >= points.length) return;
    setState(() {
      points[index].position = position;
      selectedPoint = index;
    });
  }

  void deletePoint(int index) {
    if (index < 0 || index >= points.length) return;
    setState(() {
      points.removeAt(index);
      selectedPoint = points.isEmpty ? -1 : math.min(index, points.length - 1);
      final Offset c = polygonCentroid();
      for (final ChakraTransform t in transforms) t.center = c;
    });
  }

  void updateCenterFromPlot() {
    final Offset c = polygonCentroid();
    setState(() {
      for (final ChakraTransform t in transforms) t.center = c;
    });
    msg('सभी Chakra को plot के नए center पर रखा गया।');
  }

  void go(int index) => setState(() => tab = index.clamp(0, 4).toInt());

  @override
  Widget build(BuildContext context) {
    final List<String> labels = <String>['Customer', 'Plot', 'Settings', 'Chakra', 'PDF Preview'];
    return Scaffold(
      appBar: AppBar(
        title: Text('Vastu Plot + Chakra • ${labels[tab]}'),
        actions: <Widget>[
          if (tab < 4)
            IconButton(
              tooltip: 'Next',
              onPressed: () => go(tab + 1),
              icon: const Icon(Icons.arrow_forward),
            ),
        ],
      ),
      body: IndexedStack(
        index: tab,
        children: <Widget>[
          _customerPage(),
          _plotPage(),
          _settingsPage(),
          _chakraPage(),
          _pdfPreviewPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: go,
        destinations: const <NavigationDestination>[
          NavigationDestination(icon: Icon(Icons.person), label: 'Customer'),
          NavigationDestination(icon: Icon(Icons.crop_free), label: 'Plot'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
          NavigationDestination(icon: Icon(Icons.layers), label: 'Chakras'),
          NavigationDestination(icon: Icon(Icons.picture_as_pdf), label: 'PDF'),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text, String sub) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(text, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 3),
          Text(sub, style: Theme.of(context).textTheme.bodyMedium),
        ]),
      );

  Widget _customerPage() => ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _sectionTitle('1 • Customer', 'Customer की जानकारी यहाँ भरें।'),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Customer Name', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextField(controller: address, maxLines: 3, decoration: const InputDecoration(labelText: 'Address', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextField(controller: mobile, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Mobile Number', border: OutlineInputBorder())),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: () => go(1), icon: const Icon(Icons.arrow_forward), label: const Text('2 • Plot पर जाएँ')),
        ],
      );

  Widget _plotPage() => ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _sectionTitle('2 • Plot', 'Photo चुनें और dots से actual plot boundary बनाएं।'),
          FilledButton.icon(onPressed: pickPlot, icon: const Icon(Icons.photo_library), label: Text(plot == null ? 'Plot Photo Select करें' : 'Plot Photo बदलें')),
          const SizedBox(height: 12),
          if (plot == null)
            Container(height: 300, alignment: Alignment.center, decoration: BoxDecoration(border: Border.all(), borderRadius: BorderRadius.circular(14)), child: const Text('पहले plot photo select करें'))
          else
            PlotEditor(
              image: plot!,
              points: points,
              mode: boundaryMode,
              selectedIndex: selectedPoint,
              onSelect: (int i) => setState(() => selectedPoint = i),
              onMove: updatePoint,
              onDelete: deletePoint,
              onAdd: (Offset newPoint) {
                setState(() {
                  points.add(BoundaryPoint(newPoint));
                  selectedPoint = points.length - 1;
                });
              },
            ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: SegmentedButton<BoundaryMode>(
                  segments: const <ButtonSegment<BoundaryMode>>[
                    ButtonSegment(value: BoundaryMode.add, label: Text('ADD'), icon: Icon(Icons.add_location_alt)),
                    ButtonSegment(value: BoundaryMode.move, label: Text('MOVE'), icon: Icon(Icons.open_with)),
                    ButtonSegment(value: BoundaryMode.delete, label: Text('DELETE'), icon: Icon(Icons.delete_outline)),
                  ],
                  selected: <BoundaryMode>{boundaryMode},
                  onSelectionChanged: (Set<BoundaryMode> s) => setState(() => boundaryMode = s.first),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Clear dots',
                onPressed: plot == null ? null : () => setState(_setAutomaticCornerPoints),
                icon: const Icon(Icons.cleaning_services),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('ADD mode में photo पर tap करके dot लगाएँ। गलत लगे तो MOVE/EDIT या DELETE करें।', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Row(children: <Widget>[
            Expanded(child: OutlinedButton.icon(onPressed: points.isEmpty ? null : () => setState(() { points.clear(); selectedPoint = -1; }), icon: const Icon(Icons.clear_all), label: const Text('Clear All'))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(onPressed: points.length < 3 ? null : updateCenterFromPlot, icon: const Icon(Icons.center_focus_strong), label: const Text('Re-center Chakras'))),
          ]),
          const SizedBox(height: 8),
          Text(selectedPoint >= 0 ? 'Selected Dot: ${selectedPoint + 1}' : 'ADD mode में photo पर tap करके dot लगाएँ', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: () => go(2), icon: const Icon(Icons.arrow_forward), label: const Text('3 • Settings')),
        ],
      );

  Widget _settingsPage() => ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _sectionTitle('3 • Settings', 'Plot degree और CHKRA folder यहाँ सेट करें।'),
          TextField(
            controller: degree,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            onChanged: setDegree,
            decoration: const InputDecoration(labelText: 'Plot / North Degree', suffixText: '°', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Text('Current: ${plotDegree.toStringAsFixed(1)}°  • नए Chakra का initial degree यही होगा।'),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: loadingChakras ? null : chooseFolder, icon: const Icon(Icons.folder_open), label: Text(loadingChakras ? 'CHKRA पढ़ रहा है...' : 'CHKRA Folder Select करें')),
          if (folderName != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Selected Folder: $folderName', style: const TextStyle(fontWeight: FontWeight.bold))),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: loadingChakras ? null : refreshChakras, icon: const Icon(Icons.refresh), label: const Text('Refresh CHKRA Folder')),
          const SizedBox(height: 8),
          Text('${chakras.length} Chakra images मिलीं'),
          const SizedBox(height: 18),
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text('Workflow', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
            const SizedBox(height: 8),
            const Text('1. Customer → 2. Plot/Dots → 3. Settings → 4. सभी Chakra set करें → 5. PDF Preview → Generate PDF'),
          ]))),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: () => go(3), icon: const Icon(Icons.layers), label: const Text('4 • सभी Chakra Set करें')),
        ],
      );

  Widget _chakraPage() {
    if (plot == null || chakras.isEmpty) {
      return ListView(padding: const EdgeInsets.all(16), children: <Widget>[
        _sectionTitle('4 • Chakras', 'हर Chakra को plot के ऊपर set करें।'),
        const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('पहले Plot और CHKRA images तैयार करें। Settings में CHKRA folder चुनें।'))),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: () => go(2), icon: const Icon(Icons.settings), label: const Text('Settings खोलें')),
      ]);
    }
    return ChakraWorkspace(
      plot: plot!,
      points: points,
      chakras: chakras,
      transforms: transforms,
      plotDegree: plotDegree,
      onChanged: () => setState(() {}),
      onNext: () => go(4),
    );
  }

  Widget _pdfPreviewPage() {
    if (plot == null || chakras.isEmpty) {
      return ListView(padding: const EdgeInsets.all(16), children: <Widget>[
        _sectionTitle('5 • PDF Preview', 'PDF बनाने से पहले final pages check करें।'),
        const Text('Plot और कम से कम एक Chakra चाहिए।'),
      ]);
    }
    return PdfPreviewWorkspace(
      plot: plot!,
      points: points,
      chakras: chakras,
      transforms: transforms,
      plotDegree: plotDegree,
      clientName: name.text.trim(),
      address: address.text.trim(),
      mobile: mobile.text.trim(),
      onGenerate: makePdf,
    );
  }

  Future<ui.Image> _decodeUiImage(Uint8List bytes) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(buffer);
    final ui.Codec codec = await descriptor.instantiateCodec();
    final ui.FrameInfo frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }

  Rect _containRect(Size imageSize, Size boxSize) {
    final double scale = math.min(boxSize.width / imageSize.width, boxSize.height / imageSize.height);
    final Size fitted = Size(imageSize.width * scale, imageSize.height * scale);
    return Rect.fromLTWH((boxSize.width - fitted.width) / 2, (boxSize.height - fitted.height) / 2, fitted.width, fitted.height);
  }

  Future<Uint8List> _renderPdfComposition({
    required Uint8List plotBytes,
    required Uint8List chakraBytes,
    required ChakraTransform transform,
    required Size outputSize,
  }) async {
    final ui.Image plotImage = await _decodeUiImage(plotBytes);
    final ui.Image chakraImage = await _decodeUiImage(chakraBytes);
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawColor(Colors.white, BlendMode.srcOver);
    final Rect plotRect = _containRect(Size(plotImage.width.toDouble(), plotImage.height.toDouble()), outputSize);
    final Paint imagePaint = Paint()..filterQuality = FilterQuality.high;
    canvas.drawImageRect(plotImage, Rect.fromLTWH(0, 0, plotImage.width.toDouble(), plotImage.height.toDouble()), plotRect, imagePaint);
    _paintBoundary(canvas, plotRect, points);
    final Offset center = Offset(plotRect.left + transform.center.dx * plotRect.width, plotRect.top + transform.center.dy * plotRect.height);
    final double side = plotRect.width * transform.scale;
    final Rect dst = Rect.fromLTWH(center.dx - side / 2, center.dy - side / 2, side, side);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(transform.angle * math.pi / 180);
    canvas.translate(-center.dx, -center.dy);
    final Paint chakraPaint = Paint()..filterQuality = FilterQuality.high..color = Colors.white.withOpacity(transform.opacity);
    canvas.drawImageRect(chakraImage, Rect.fromLTWH(0, 0, chakraImage.width.toDouble(), chakraImage.height.toDouble()), dst, chakraPaint);
    canvas.restore();
    final ui.Image output = await recorder.endRecording().toImage(outputSize.width.round(), outputSize.height.round());
    final ByteData? data = await output.toByteData(format: ui.ImageByteFormat.png);
    plotImage.dispose();
    chakraImage.dispose();
    output.dispose();
    if (data == null) throw StateError('PDF composition render failed');
    return data.buffer.asUint8List();
  }

  void _paintBoundary(Canvas canvas, Rect plotRect, List<BoundaryPoint> pts) {
    if (pts.length < 2) return;
    final Paint paint = Paint()..color = Colors.green.withOpacity(.9)..strokeWidth = math.max(2, plotRect.width / 600)..style = PaintingStyle.stroke;
    final Path boundary = Path();
    for (int i = 0; i < pts.length; i++) {
      final Offset p = Offset(plotRect.left + pts[i].position.dx * plotRect.width, plotRect.top + pts[i].position.dy * plotRect.height);
      if (i == 0) boundary.moveTo(p.dx, p.dy); else boundary.lineTo(p.dx, p.dy);
    }
    if (pts.length > 2) boundary.close();
    canvas.drawPath(boundary, paint);
  }

  Future<void> makePdf() async {
    if (plot == null || chakras.isEmpty) {
      msg('Plot और कम से कम 1 Chakra जरूरी है।');
      return;
    }
    final pw.Document doc = pw.Document();
    final Uint8List plotBytes = await plot!.readAsBytes();
    doc.addPage(pw.Page(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.all(28), build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
      pw.Text('Vastu Plot + Chakra Report', style: pw.TextStyle(fontSize: 23, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 16),
      pw.Text('Client Name: ${name.text.trim()}'),
      pw.Text('Address: ${address.text.trim()}'),
      pw.Text('Mobile: ${mobile.text.trim()}'),
      pw.SizedBox(height: 10),
      pw.Text('Plot / North Degree: ${plotDegree.toStringAsFixed(1)}°'),
      pw.Text('Total Chakra Pages: ${chakras.length}'),
      pw.SizedBox(height: 14),
      pw.Expanded(child: pw.Center(child: pw.Image(pw.MemoryImage(plotBytes), fit: pw.BoxFit.contain))),
      pw.SizedBox(height: 8),
      pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('Ghanshyam Lohani', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold))),
    ])));
    for (int i = 0; i < chakras.length; i++) {
      final ChakraTransform t = transforms[i];
      final Uint8List composition = await _renderPdfComposition(plotBytes: plotBytes, chakraBytes: chakras[i].bytes, transform: t, outputSize: const Size(1400, 1900));
      doc.addPage(pw.Page(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.all(18), build: (_) => pw.Column(children: <pw.Widget>[
        pw.Text('Chakra ${i + 1} • ${chakras[i].name}', style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
        pw.Expanded(child: pw.Image(pw.MemoryImage(composition), fit: pw.BoxFit.contain)),
        pw.SizedBox(height: 5),
        pw.Text('Plot Degree: ${plotDegree.toStringAsFixed(1)}° | Chakra Degree: ${t.angle.toStringAsFixed(1)}°', style: const pw.TextStyle(fontSize: 9)),
        pw.SizedBox(height: 3),
        pw.Text('Ghanshyam Lohani', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
      ])));
    }
    final List<int> bytes = await doc.save();
    Directory target = Directory('/storage/emulated/0/Download');
    if (!await target.exists()) target = await Directory.systemTemp.createTemp('vastu_report_');
    final File output = File(path.join(target.path, 'Vastu_Plot_Chakra_Report.pdf'));
    await output.writeAsBytes(bytes, flush: true);
    msg('PDF तैयार: ${output.path}');
  }
}

class PlotEditor extends StatelessWidget {
  const PlotEditor({
    super.key,
    required this.image,
    required this.points,
    required this.mode,
    required this.selectedIndex,
    required this.onSelect,
    required this.onMove,
    required this.onDelete,
    required this.onAdd,
  });
  final File image;
  final List<BoundaryPoint> points;
  final BoundaryMode mode;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final void Function(int, Offset) onMove;
  final ValueChanged<int> onDelete;
  final ValueChanged<Offset> onAdd;

  Offset norm(Offset p, Size s) => Offset(
        (p.dx / s.width).clamp(0.0, 1.0),
        (p.dy / s.height).clamp(0.0, 1.0),
      );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final double width = box.maxWidth.isFinite ? box.maxWidth : 360;
          final double height = math.max(360, width * .78);
          final Size size = Size(width, height);
          return Column(
            children: <Widget>[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(mode == BoundaryMode.add
                        ? Icons.add_location_alt
                        : mode == BoundaryMode.move
                            ? Icons.open_with
                            : Icons.delete_outline),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        mode == BoundaryMode.add
                            ? 'Photo पर tap करके नए dots लगाएँ'
                            : mode == BoundaryMode.move
                                ? 'Dots को finger से पकड़कर सही जगह move करें'
                                : 'जिस dot को हटाना है उसे tap करें',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text('${points.length} dots'),
                  ],
                ),
              ),
              Container(
                height: height,
                width: width,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
                  border: Border.all(color: Theme.of(context).colorScheme.outline, width: 1.5),
                ),
                clipBehavior: Clip.antiAlias,
                child: GestureDetector(
                  onTapUp: (TapUpDetails details) {
                    if (mode == BoundaryMode.add) {
                      onAdd(norm(details.localPosition, size));
                    }
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      Image.file(image, fit: BoxFit.contain, alignment: Alignment.center),
                      IgnorePointer(child: CustomPaint(painter: BoundaryPainter(points))),
                      for (int i = 0; i < points.length; i++)
                        Positioned(
                          left: points[i].position.dx * width - 19,
                          top: points[i].position.dy * height - 19,
                          width: 38,
                          height: 38,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              onSelect(i);
                              if (mode == BoundaryMode.delete) onDelete(i);
                            },
                            onPanStart: (_) => onSelect(i),
                            onPanUpdate: (DragUpdateDetails d) {
                              if (mode == BoundaryMode.move) {
                                final Offset old = points[i].position;
                                onMove(i, norm(Offset(old.dx * width + d.delta.dx, old.dy * height + d.delta.dy), size));
                              }
                            },
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: selectedIndex == i ? Colors.orange : Colors.red,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2.5),
                                boxShadow: const <BoxShadow>[
                                  BoxShadow(blurRadius: 4, offset: Offset(0, 2), color: Colors.black26),
                                ],
                              ),
                              child: Text(
                                '${i + 1}',
                                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      );
}

class BoundaryPainter extends CustomPainter {
  const BoundaryPainter(this.points);
  final List<BoundaryPoint> points;
  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final Paint paint = Paint()..color = Colors.green..strokeWidth = 3..style = PaintingStyle.stroke;
    final Path p = Path();
    for (int i = 0; i < points.length; i++) {
      final Offset q = Offset(points[i].position.dx * size.width, points[i].position.dy * size.height);
      if (i == 0) p.moveTo(q.dx, q.dy); else p.lineTo(q.dx, q.dy);
    }
    if (points.length > 2) p.close();
    canvas.drawPath(p, paint);
  }
  @override
  bool shouldRepaint(covariant BoundaryPainter oldDelegate) => true;
}

class ChakraWorkspace extends StatefulWidget {
  const ChakraWorkspace({super.key, required this.plot, required this.points, required this.chakras, required this.transforms, required this.plotDegree, required this.onChanged, required this.onNext});
  final File plot;
  final List<BoundaryPoint> points;
  final List<ChakraImage> chakras;
  final List<ChakraTransform> transforms;
  final double plotDegree;
  final VoidCallback onChanged;
  final VoidCallback onNext;
  @override
  State<ChakraWorkspace> createState() => _ChakraWorkspaceState();
}

class _ChakraWorkspaceState extends State<ChakraWorkspace> {
  int page = 0;
  final List<double> startAngles = <double>[];
  final List<double> startScales = <double>[];
  final List<Offset> startCenters = <Offset>[];
  ui.Image? plotImage;

  @override
  void initState() {
    super.initState();
    _loadPlot();
    _ensureStarts();
  }

  void _ensureStarts() {
    while (startAngles.length < widget.chakras.length) startAngles.add(0);
    while (startScales.length < widget.chakras.length) startScales.add(1);
    while (startCenters.length < widget.chakras.length) startCenters.add(const Offset(.5, .5));
  }

  Future<void> _loadPlot() async {
    final Uint8List bytes = await widget.plot.readAsBytes();
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(buffer);
    final ui.Codec codec = await descriptor.instantiateCodec();
    final ui.FrameInfo frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    if (mounted) setState(() => plotImage = frame.image);
  }

  @override
  void didUpdateWidget(covariant ChakraWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureStarts();
  }

  @override
  void dispose() {
    plotImage?.dispose();
    super.dispose();
  }

  double norm(double v) {
    final double r = v % 360;
    return r < 0 ? r + 360 : r;
  }

  Offset polygonCenter() {
    if (widget.points.isEmpty) return const Offset(.5, .5);
    if (widget.points.length < 3) {
      double x = 0;
      double y = 0;
      for (final BoundaryPoint p in widget.points) { x += p.position.dx; y += p.position.dy; }
      return Offset(x / widget.points.length, y / widget.points.length);
    }
    double area2 = 0;
    double cx = 0;
    double cy = 0;
    for (int i = 0; i < widget.points.length; i++) {
      final Offset a = widget.points[i].position;
      final Offset b = widget.points[(i + 1) % widget.points.length].position;
      final double cross = a.dx * b.dy - b.dx * a.dy;
      area2 += cross;
      cx += (a.dx + b.dx) * cross;
      cy += (a.dy + b.dy) * cross;
    }
    if (area2.abs() < 1e-9) return const Offset(.5, .5);
    return Offset(cx / (3 * area2), cy / (3 * area2));
  }

  void reset() {
    final ChakraTransform t = widget.transforms[page];
    setState(() {
      t.angle = widget.plotDegree;
      t.scale = .84;
      t.center = polygonCenter();
      t.opacity = .78;
    });
    widget.onChanged();
  }

  void rotate(double amount) {
    setState(() => widget.transforms[page].angle = norm(widget.transforms[page].angle + amount));
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    _ensureStarts();
    final ChakraTransform t = widget.transforms[page];
    return Column(
      children: <Widget>[
        Expanded(
          child: PageView.builder(
            itemCount: widget.chakras.length,
            onPageChanged: (int i) => setState(() => page = i),
            itemBuilder: (BuildContext context, int i) => _composition(i),
          ),
        ),
        Material(
          elevation: 6,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text('Chakra ${page + 1}/${widget.chakras.length}', style: const TextStyle(fontWeight: FontWeight.bold)),
                      const Spacer(),
                      Text('${t.angle.toStringAsFixed(1)}°'),
                    ],
                  ),
                  Slider(
                    min: 0,
                    max: 360,
                    value: t.angle.clamp(0.0, 360.0).toDouble(),
                    onChanged: (double v) {
                      setState(() => t.angle = v);
                      widget.onChanged();
                    },
                  ),
                  Row(
                    children: <Widget>[
                      const Icon(Icons.zoom_out),
                      Expanded(
                        child: Slider(
                          min: .15,
                          max: 3,
                          value: t.scale.clamp(.15, 3).toDouble(),
                          onChanged: (double v) {
                            setState(() => t.scale = v);
                            widget.onChanged();
                          },
                        ),
                      ),
                      const Icon(Icons.zoom_in),
                      Text('${(t.scale * 100).round()}%'),
                    ],
                  ),
                  Row(
                    children: <Widget>[
                      const Text('Opacity'),
                      Expanded(
                        child: Slider(
                          min: .05,
                          max: 1,
                          value: t.opacity.clamp(.05, 1).toDouble(),
                          onChanged: (double v) {
                            setState(() => t.opacity = v);
                            widget.onChanged();
                          },
                        ),
                      ),
                      Text('${(t.opacity * 100).round()}%'),
                    ],
                  ),
                  Row(
                    children: <Widget>[
                      Expanded(child: OutlinedButton(onPressed: () => rotate(-1), child: const Text('-1°'))),
                      const SizedBox(width: 5),
                      Expanded(child: OutlinedButton(onPressed: () => rotate(1), child: const Text('+1°'))),
                      const SizedBox(width: 5),
                      Expanded(child: FilledButton(onPressed: reset, child: const Text('Reset'))),
                    ],
                  ),
                  const Text('1 finger = Move • 2 fingers = Zoom + Rotate • Plot center = blue cross', textAlign: TextAlign.center, style: TextStyle(fontSize: 11)),
                  const SizedBox(height: 5),
                  FilledButton.icon(onPressed: widget.onNext, icon: const Icon(Icons.picture_as_pdf), label: const Text('5 • PDF Preview')),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Rect contain(Size imageSize, Size boxSize) {
    final double s = math.min(boxSize.width / imageSize.width, boxSize.height / imageSize.height);
    final Size fitted = Size(imageSize.width * s, imageSize.height * s);
    return Rect.fromLTWH((boxSize.width - fitted.width) / 2, (boxSize.height - fitted.height) / 2, fitted.width, fitted.height);
  }

  Widget _composition(int index) {
    final ChakraTransform t = widget.transforms[index];
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints box) {
      final Size viewport = Size(box.maxWidth, math.max(200, box.maxHeight));
      final Size imgSize = plotImage == null ? const Size(1, 1) : Size(plotImage!.width.toDouble(), plotImage!.height.toDouble());
      final Rect plotRect = contain(imgSize, viewport);
      final Offset center = Offset(plotRect.left + t.center.dx * plotRect.width, plotRect.top + t.center.dy * plotRect.height);
      final double side = plotRect.width * t.scale;
      return Stack(children: <Widget>[
        Positioned.fill(child: Image.file(widget.plot, fit: BoxFit.contain)),
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: BoundaryPainter(widget.points)))),
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: CenterMarkerPainter(center: t.center, rect: plotRect)))),
        Positioned(left: center.dx - side / 2, top: center.dy - side / 2, width: side, height: side, child: IgnorePointer(child: Transform.rotate(angle: t.angle * math.pi / 180, child: Opacity(opacity: t.opacity, child: Image.memory(widget.chakras[index].bytes, fit: BoxFit.fill))))),
        Positioned(top: 8, left: 8, right: 8, child: Align(alignment: Alignment.topLeft, child: DecoratedBox(decoration: BoxDecoration(color: Colors.white.withOpacity(.86), borderRadius: BorderRadius.circular(6)), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4), child: Text('Chakra ${index + 1} • ${widget.chakras[index].name} • ${t.angle.toStringAsFixed(1)}°', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)))))) ,
        Positioned.fill(child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onScaleStart: (_) {
            startAngles[index] = t.angle;
            startScales[index] = t.scale;
            startCenters[index] = t.center;
          },
          onScaleUpdate: (ScaleUpdateDetails d) {
            setState(() {
              t.scale = (startScales[index] * d.scale).clamp(.15, 3.0).toDouble();
              t.angle = norm(startAngles[index] + d.rotation * 180 / math.pi);
              t.center = Offset((startCenters[index].dx + d.focalPointDelta.dx / plotRect.width).clamp(-.5, 1.5), (startCenters[index].dy + d.focalPointDelta.dy / plotRect.height).clamp(-.5, 1.5));
            });
            widget.onChanged();
          },
        )),
      ]);
    });
  }
}

class CenterMarkerPainter extends CustomPainter {
  const CenterMarkerPainter({required this.center, required this.rect});
  final Offset center;
  final Rect rect;
  @override
  void paint(Canvas canvas, Size size) {
    final Offset p = Offset(rect.left + center.dx * rect.width, rect.top + center.dy * rect.height);
    final Paint paint = Paint()..color = Colors.blue..strokeWidth = 2;
    canvas.drawCircle(p, 5, paint);
    canvas.drawLine(Offset(p.dx - 12, p.dy), Offset(p.dx + 12, p.dy), paint);
    canvas.drawLine(Offset(p.dx, p.dy - 12), Offset(p.dx, p.dy + 12), paint);
  }
  @override
  bool shouldRepaint(covariant CenterMarkerPainter oldDelegate) => oldDelegate.center != center || oldDelegate.rect != rect;
}

class PdfPreviewWorkspace extends StatefulWidget {
  const PdfPreviewWorkspace({super.key, required this.plot, required this.points, required this.chakras, required this.transforms, required this.plotDegree, required this.clientName, required this.address, required this.mobile, required this.onGenerate});
  final File plot;
  final List<BoundaryPoint> points;
  final List<ChakraImage> chakras;
  final List<ChakraTransform> transforms;
  final double plotDegree;
  final String clientName;
  final String address;
  final String mobile;
  final Future<void> Function() onGenerate;
  @override
  State<PdfPreviewWorkspace> createState() => _PdfPreviewWorkspaceState();
}

class _PdfPreviewWorkspaceState extends State<PdfPreviewWorkspace> {
  int page = 0;
  ui.Image? plotImage;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final Uint8List b = await widget.plot.readAsBytes();
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(b);
    final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(buffer);
    final ui.Codec codec = await descriptor.instantiateCodec();
    final ui.FrameInfo frame = await codec.getNextFrame();
    codec.dispose(); descriptor.dispose(); buffer.dispose();
    if (mounted) setState(() => plotImage = frame.image);
  }
  @override
  void dispose() { plotImage?.dispose(); super.dispose(); }
  Rect contain(Size imageSize, Size boxSize) {
    final double s = math.min(boxSize.width / imageSize.width, boxSize.height / imageSize.height);
    final Size fitted = Size(imageSize.width * s, imageSize.height * s);
    return Rect.fromLTWH((boxSize.width - fitted.width) / 2, (boxSize.height - fitted.height) / 2, fitted.width, fitted.height);
  }
  @override
  Widget build(BuildContext context) => Column(children: <Widget>[
    Expanded(child: PageView.builder(itemCount: widget.chakras.length + 1, onPageChanged: (int i) => setState(() => page = i), itemBuilder: (_, int i) => i == 0 ? _cover() : _chakra(i - 1))),
    SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(10), child: FilledButton.icon(onPressed: widget.onGenerate, icon: const Icon(Icons.download), label: Text('Generate ${widget.chakras.length + 1} Page PDF')))),
  ]);
  Widget _cover() => ListView(padding: const EdgeInsets.all(14), children: <Widget>[
    Text('PAGE 1 • COVER / CLIENT', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
    const SizedBox(height: 8),
    Text('Client: ${widget.clientName.isEmpty ? '-' : widget.clientName}'),
    Text('Address: ${widget.address.isEmpty ? '-' : widget.address}'),
    Text('Mobile: ${widget.mobile.isEmpty ? '-' : widget.mobile}'),
    Text('Plot Degree: ${widget.plotDegree.toStringAsFixed(1)}°'),
    const SizedBox(height: 10),
    Image.file(widget.plot, fit: BoxFit.contain, height: 500),
    const SizedBox(height: 8),
    const Align(alignment: Alignment.centerRight, child: Text('Ghanshyam Lohani', style: TextStyle(fontWeight: FontWeight.bold))),
  ]);
  Widget _chakra(int index) => LayoutBuilder(builder: (BuildContext context, BoxConstraints box) {
    final ChakraTransform t = widget.transforms[index];
    final Size viewport = Size(box.maxWidth, math.max(220, box.maxHeight));
    final Size imgSize = plotImage == null ? const Size(1, 1) : Size(plotImage!.width.toDouble(), plotImage!.height.toDouble());
    final Rect plotRect = contain(imgSize, viewport);
    final Offset center = Offset(plotRect.left + t.center.dx * plotRect.width, plotRect.top + t.center.dy * plotRect.height);
    final double side = plotRect.width * t.scale;
    return Stack(children: <Widget>[
      Positioned.fill(child: Image.file(widget.plot, fit: BoxFit.contain)),
      Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: BoundaryPainter(widget.points)))),
      Positioned(left: center.dx - side / 2, top: center.dy - side / 2, width: side, height: side, child: IgnorePointer(child: Transform.rotate(angle: t.angle * math.pi / 180, child: Opacity(opacity: t.opacity, child: Image.memory(widget.chakras[index].bytes, fit: BoxFit.fill))))),
      Positioned(top: 6, left: 6, right: 6, child: Text('Chakra ${index + 1} • ${widget.chakras[index].name} • Plot ${widget.plotDegree.toStringAsFixed(1)}° • Chakra ${t.angle.toStringAsFixed(1)}°', style: const TextStyle(fontWeight: FontWeight.bold, backgroundColor: Colors.white))),
      const Positioned(bottom: 8, right: 8, child: Text('Ghanshyam Lohani', style: TextStyle(fontWeight: FontWeight.bold))),
    ]);
  });
}

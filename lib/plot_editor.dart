import 'package:flutter/material.dart';

class IrregularPlotEditor extends StatefulWidget {
  @override
  _IrregularPlotEditorState createState() => _IrregularPlotEditorState();
}

class _IrregularPlotEditorState extends State<IrregularPlotEditor> {
  // Yahan 4 ki jagah unlimited corners store ho sakte hain
  List<Offset> corners = []; 
  int? draggingIndex;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Irregular Plot Editor"),
        actions: [
          IconButton(
            icon: Icon(Icons.clear),
            onPressed: () => setState(() => corners.clear()), // Clear all dots
          )
        ],
      ),
      body: GestureDetector(
        // Naya corner add karne ke liye screen par tap karein
        onTapDown: (TapDownDetails details) {
          setState(() {
            corners.add(details.localPosition);
          });
        },
        // Kisi bhi dot ko pakad kar drag (khiskane) ke liye
        onPanStart: (DragStartDetails details) {
          double minDistance = 30.0; // Touch sensitivity area
          for (int i = 0; i < corners.length; i++) {
            if ((corners[i] - details.localPosition).distance < minDistance) {
              draggingIndex = i;
              break;
            }
          }
        },
        onPanUpdate: (DragUpdateDetails details) {
          if (draggingIndex != null) {
            setState(() {
              corners[draggingIndex!] = details.localPosition;
            });
          }
        },
        onPanEnd: (DragEndDetails details) {
          draggingIndex = null;
        },
        child: Container(
          color: Colors.grey[200], // Background plot area
          width: double.infinity,
          height: double.infinity,
          child: CustomPaint(
            painter: PlotPainter(corners),
          ),
        ),
      ),
    );
  }
}

class PlotPainter extends CustomPainter {
  final List<Offset> corners;

  PlotPainter(this.corners);

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.isEmpty) return;

    // 1. Plot ki Boundary Line (Path) draw karne ke liye
    final Paint linePaint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;

    final Paint fillPaint = Paint()
      ..color = Colors.blue.withOpacity(0.2)
      ..style = PaintingStyle.fill;

    Path plotPath = Path();
    plotPath.moveTo(corners[0].dx, corners[0].dy);

    for (int i = 1; i < corners.length; i++) {
      plotPath.lineTo(corners[i].dx, corners[i].dy);
    }
    
    // Agar 3 ya usse zyada dots hain, toh shape ko close kar do
    if (corners.length > 2) {
      plotPath.close(); 
      canvas.drawPath(plotPath, fillPaint);
    }
    canvas.drawPath(plotPath, linePaint);

    // 2. Corners (Kono) par Dots draw karne ke liye
    final Paint dotPaint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    for (var corner in corners) {
      canvas.drawCircle(corner, 8.0, dotPaint); // 8.0 dot ka size hai
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true; // Har baar screen update hone par redraw karega
  }
}

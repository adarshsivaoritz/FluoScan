// FluoScan v0.2
// Flutter Web fluorescent Code 128 reader.
// Web-only by design, matching the pH-meterV2 GitHub Pages workflow.

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:js_util' as js_util;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

void main() {
  runApp(const FluoScanApp());
}

enum InkMode { auto, diabp, dianbp, diasf }

extension InkModeLabel on InkMode {
  String get label {
    switch (this) {
      case InkMode.auto:
        return 'AUTO';
      case InkMode.diabp:
        return 'DiABP';
      case InkMode.dianbp:
        return 'DiANBP';
      case InkMode.diasf:
        return 'DiASF';
    }
  }
}

class FluoScanApp extends StatelessWidget {
  const FluoScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FluoScan',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        scaffoldBackgroundColor: const Color(0xFFF4F6FA),
      ),
      home: const ScannerPage(),
    );
  }
}

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScanCandidate {
  final String text;
  final String format;
  final String preset;
  final double band;
  final double thresholdOffset;
  final String dataUrl;

  const _ScanCandidate({
    required this.text,
    required this.format,
    required this.preset,
    required this.band,
    required this.thresholdOffset,
    required this.dataUrl,
  });
}

class _ScannerPageState extends State<ScannerPage> {
  static const String _cameraViewType = 'fluoscan-camera-view-v02';

  late final html.VideoElement _video;
  final html.CanvasElement _sourceCanvas = html.CanvasElement();
  html.MediaStream? _stream;
  Timer? _autoTimer;

  InkMode _mode = InkMode.auto;
  bool _cameraRunning = false;
  bool _autoScan = false;
  bool _busy = false;
  double _sensitivity = 0.0;

  String _status = 'Ready. Start the camera or test one of the supplied images.';
  String _decoded = '--';
  String _details = '';
  Uint8List? _capturedRoiPng;
  Uint8List? _processedPng;

  @override
  void initState() {
    super.initState();
    _video = html.VideoElement()
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover'
      ..style.backgroundColor = '#05070b';

    ui_web.platformViewRegistry.registerViewFactory(
      _cameraViewType,
      (int viewId) => _video,
    );
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _stopCameraInternal();
    super.dispose();
  }

  Future<void> _startCamera() async {
    try {
      setState(() {
        _status = 'Requesting camera permission…';
      });

      final mediaDevices = html.window.navigator.mediaDevices;
      final stream = await mediaDevices!.getUserMedia({
        'video': {
          'facingMode': {'ideal': 'environment'},
          'width': {'ideal': 1280},
          'height': {'ideal': 720},
        },
        'audio': false,
      });

      _stream = stream;
      _video.srcObject = stream;
      await _video.play();

      if (!mounted) return;
      setState(() {
        _cameraRunning = true;
        _status = 'Camera ready. Illuminate the print with UV and align one barcode in the guide.';
      });
      _restartAutoTimer();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Camera error: $e';
      });
    }
  }

  void _stopCameraInternal() {
    _autoTimer?.cancel();
    _autoTimer = null;
    final stream = _stream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        track.stop();
      }
    }
    _stream = null;
    _video.srcObject = null;
  }

  void _stopCamera() {
    _stopCameraInternal();
    if (!mounted) return;
    setState(() {
      _cameraRunning = false;
      _autoScan = false;
      _status = 'Camera stopped.';
    });
  }

  void _restartAutoTimer() {
    _autoTimer?.cancel();
    if (!_autoScan || !_cameraRunning) return;
    _autoTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      if (!_busy) {
        _scanCameraFrame(quiet: true);
      }
    });
  }

  Future<void> _scanCameraFrame({bool quiet = false}) async {
    if (!_cameraRunning) {
      if (!quiet) {
        setState(() => _status = 'Start the camera first.');
      }
      return;
    }

    final w = _video.videoWidth;
    final h = _video.videoHeight;
    if (w <= 0 || h <= 0) {
      if (!quiet) setState(() => _status = 'Waiting for a camera frame…');
      return;
    }

    _sourceCanvas.width = w;
    _sourceCanvas.height = h;
    _sourceCanvas.context2D.drawImageScaled(_video, 0, 0, w, h);

    // The guide is drawn over a video using object-fit: cover. Map that
    // visible guide back into source-camera pixels so we analyse what the
    // user actually placed inside the guide, not the entire camera frame.
    final roi = _cameraGuideRect(w, h);
    await _analyseCanvas(
      _sourceCanvas,
      sourceName: 'live camera',
      quiet: quiet,
      roiX: roi.left,
      roiY: roi.top,
      roiWidth: roi.width,
      roiHeight: roi.height,
    );
  }

  math.Rectangle<int> _cameraGuideRect(int sourceWidth, int sourceHeight) {
    final displayWidth = _video.clientWidth > 0
        ? _video.clientWidth.toDouble()
        : sourceWidth.toDouble();
    final displayHeight = _video.clientHeight > 0
        ? _video.clientHeight.toDouble()
        : sourceHeight.toDouble();

    final scale = math.max(
      displayWidth / sourceWidth,
      displayHeight / sourceHeight,
    );
    final renderedWidth = sourceWidth * scale;
    final renderedHeight = sourceHeight * scale;
    final offsetX = (displayWidth - renderedWidth) / 2.0;
    final offsetY = (displayHeight - renderedHeight) / 2.0;

    // Must match the FractionallySizedBox in _cameraPanel.
    final guideLeft = displayWidth * 0.05;
    final guideTop = displayHeight * (0.50 - 0.42 / 2.0);
    final guideWidth = displayWidth * 0.90;
    final guideHeight = displayHeight * 0.42;

    var x = ((guideLeft - offsetX) / scale).round();
    var y = ((guideTop - offsetY) / scale).round();
    var w = (guideWidth / scale).round();
    var h = (guideHeight / scale).round();

    x = x.clamp(0, sourceWidth - 1).toInt();
    y = y.clamp(0, sourceHeight - 1).toInt();
    w = w.clamp(1, sourceWidth - x).toInt();
    h = h.clamp(1, sourceHeight - y).toInt();
    return math.Rectangle<int>(x, y, w, h);
  }

  Future<void> _chooseImage() async {
    final input = html.FileUploadInputElement()..accept = 'image/*';
    input.click();
    await input.onChange.first;
    if (input.files == null || input.files!.isEmpty) return;

    final file = input.files!.first;
    final reader = html.FileReader();
    reader.readAsDataUrl(file);
    await reader.onLoad.first;
    final src = reader.result as String;
    await _loadImageSource(src, sourceName: file.name);
  }

  Future<void> _loadSample(String path, InkMode suggestedMode) async {
    setState(() {
      _mode = suggestedMode;
      _status = 'Loading sample…';
    });
    await _loadImageSource(path, sourceName: path.split('/').last);
  }

  Future<void> _loadImageSource(String src, {required String sourceName}) async {
    try {
      final img = html.ImageElement();
      final completer = Completer<void>();
      img.onLoad.first.then((_) => completer.complete());
      img.onError.first.then((_) {
        if (!completer.isCompleted) {
          completer.completeError('Unable to load image');
        }
      });
      img.src = src;
      await completer.future;

      final w = img.naturalWidth;
      final h = img.naturalHeight;
      _sourceCanvas.width = w;
      _sourceCanvas.height = h;
      _sourceCanvas.context2D.drawImageScaled(img, 0, 0, w, h);
      await _analyseCanvas(_sourceCanvas, sourceName: sourceName);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Image error: $e');
    }
  }

  Future<void> _analyseCanvas(
    html.CanvasElement canvas, {
    required String sourceName,
    bool quiet = false,
    int roiX = 0,
    int roiY = 0,
    int? roiWidth,
    int? roiHeight,
  }) async {
    if (_busy) return;
    _busy = true;
    if (mounted) {
      setState(() {
        if (!quiet) {
          _status = 'Scanning $sourceName…';
          _decoded = '--';
          _details = '';
        }
      });
    }

    try {
      final fullWidth = canvas.width ?? 0;
      final fullHeight = canvas.height ?? 0;
      if (fullWidth < 100 || fullHeight < 40) {
        throw 'Image is too small for reliable barcode analysis.';
      }

      final x = roiX.clamp(0, fullWidth - 1).toInt();
      final y = roiY.clamp(0, fullHeight - 1).toInt();
      final width = (roiWidth ?? (fullWidth - x)).clamp(1, fullWidth - x).toInt();
      final height = (roiHeight ?? (fullHeight - y)).clamp(1, fullHeight - y).toInt();
      if (width < 100 || height < 30) {
        throw 'Barcode guide region is too small.';
      }

      final roiData = canvas.context2D.getImageData(x, y, width, height);
      final roiCanvas = html.CanvasElement(width: width, height: height);
      roiCanvas.context2D.putImageData(roiData, 0, 0);
      final roiDataUrl = roiCanvas.toDataUrl('image/png');
      final roiRaw = roiDataUrl.split(',').last;
      if (mounted) {
        setState(() => _capturedRoiPng = base64Decode(roiRaw));
      }

      // First try the actual guide image directly. This makes FluoScan a
      // useful sanity check with an ordinary black/white barcode and also
      // catches fluorescent prints that already have enough optical contrast.
      final direct = await _decodeWithZxing(roiDataUrl);
      if (direct != null && direct.$1.trim().isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _decoded = direct.$1;
          _details = 'Direct guide decode • ${direct.$2}';
          _processedPng = null;
          _status = 'Decoded successfully from $sourceName.';
        });
        return;
      }

      final pixels = roiData.data;
      final modes = _mode == InkMode.auto
          ? <InkMode>[InkMode.diabp, InkMode.dianbp, InkMode.diasf]
          : <InkMode>[_mode];

      // Multiple scan lines are tried independently inside the guide. This
      // tolerates rough/wavy printed edges better than averaging the full bar
      // height and also gives ZXing several independent reconstructions.
      const bands = <double>[0.24, 0.34, 0.44, 0.50, 0.56, 0.66, 0.76];
      final userShift = _sensitivity;
      final thresholdOffsets = <double>[
        userShift,
        userShift - 0.04,
        userShift + 0.04,
        userShift - 0.08,
        userShift + 0.08,
        userShift - 0.14,
        userShift + 0.14,
      ];

      _ScanCandidate? winner;
      String? diagnosticDataUrl;
      String diagnosticLabel = '';

      for (final mode in modes) {
        for (final band in bands) {
          final profile = _extractProfile(
            pixels,
            width,
            height,
            mode,
            band,
          );
          final baseThreshold = _otsu(profile);
          final sorted = List<double>.from(profile)..sort();
          final p05 = _percentileSorted(sorted, 0.05);
          final p95 = _percentileSorted(sorted, 0.95);
          final spread = math.max(1.0, p95 - p05);

          for (final offset in thresholdOffsets) {
            final threshold = baseThreshold + offset * spread;
            final brightBits = profile.map((v) => v > threshold).toList(growable: false);

            // Bright-bars is the expected fluorescent case. Dark-bars is
            // deliberately tested too, so conventional barcodes and unusual
            // emission/background combinations are not rejected by polarity.
            for (var polarity = 0; polarity < 2; polarity++) {
              var bits = polarity == 0
                  ? List<bool>.from(brightBits)
                  : brightBits.map((v) => !v).toList(growable: false);
              bits = _repairShortRuns(bits);

              // Some webcams/front cameras are mirrored. Test both directions
              // instead of relying on how a browser/driver presents the image.
              for (var mirrored = 0; mirrored < 2; mirrored++) {
                final candidateBits = mirrored == 0
                    ? bits
                    : bits.reversed.toList(growable: false);
                final reconstructed = _reconstructBarcode(candidateBits);
                if (reconstructed == null) continue;

                if (diagnosticDataUrl == null) {
                  diagnosticDataUrl = reconstructed;
                  diagnosticLabel =
                      '${mode.label} • band ${(band * 100).round()}% • '
                      '${polarity == 0 ? 'bright bars' : 'dark bars'} • '
                      '${mirrored == 0 ? 'normal' : 'mirrored'}';
                }

                final result = await _decodeWithZxing(reconstructed);
                if (result != null && result.$1.trim().isNotEmpty) {
                  winner = _ScanCandidate(
                    text: result.$1,
                    format: result.$2,
                    preset:
                        '${mode.label}/${polarity == 0 ? 'bright' : 'dark'}${mirrored == 1 ? '/mirror' : ''}',
                    band: band,
                    thresholdOffset: offset,
                    dataUrl: reconstructed,
                  );
                  break;
                }
              }
              if (winner != null) break;
            }
            if (winner != null) break;
          }
          if (winner != null) break;
        }
        if (winner != null) break;
      }

      if (!mounted) return;
      if (winner != null) {
        final raw = winner.dataUrl.split(',').last;
        setState(() {
          _decoded = winner!.text;
          _details =
              '${winner!.format} • ${winner!.preset} • band ${(winner!.band * 100).round()}% • threshold ${winner!.thresholdOffset.toStringAsFixed(2)}';
          _processedPng = base64Decode(raw);
          _status = 'Decoded successfully from $sourceName.';
        });
      } else if (!quiet) {
        Uint8List? diagnostic;
        if (diagnosticDataUrl != null) {
          diagnostic = base64Decode(diagnosticDataUrl.split(',').last);
        }
        setState(() {
          _decoded = '--';
          _details = diagnosticLabel.isEmpty
              ? 'No reconstruction was produced.'
              : 'Last diagnostic: $diagnosticLabel';
          _processedPng = diagnostic;
          _status =
              'Scan completed, but no valid barcode was decoded. Check the captured guide region and reconstructed barcode below.';
        });
      }
    } catch (e) {
      if (!quiet && mounted) {
        setState(() => _status = 'Processing error: $e');
      }
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  List<double> _extractProfile(
    Uint8ClampedList pixels,
    int width,
    int height,
    InkMode mode,
    double bandFraction,
  ) {
    final x0 = (width * 0.03).round();
    final x1 = (width * 0.97).round();
    final centreY = (height * bandFraction).round();
    final halfThickness = math.max(1, height ~/ 180);
    final y0 = math.max(0, centreY - halfThickness);
    final y1 = math.min(height - 1, centreY + halfThickness);

    final profile = List<double>.filled(x1 - x0, 0.0);
    for (var x = x0; x < x1; x++) {
      var sum = 0.0;
      var n = 0;
      for (var y = y0; y <= y1; y++) {
        final i = (y * width + x) * 4;
        final r = pixels[i].toDouble();
        final g = pixels[i + 1].toDouble();
        final b = pixels[i + 2].toDouble();
        sum += _fluorescenceScore(r, g, b, mode);
        n++;
      }
      profile[x - x0] = sum / math.max(1, n);
    }

    // Light 1D smoothing only; stronger smoothing would distort narrow modules.
    if (profile.length >= 3) {
      final smooth = List<double>.from(profile);
      for (var i = 1; i < profile.length - 1; i++) {
        smooth[i] = (profile[i - 1] + profile[i] + profile[i + 1]) / 3.0;
      }
      return smooth;
    }
    return profile;
  }

  double _fluorescenceScore(double r, double g, double b, InkMode mode) {
    switch (mode) {
      case InkMode.diabp:
        // Green/yellow emission against blue UV background.
        return g + 0.15 * r - 0.75 * b;
      case InkMode.dianbp:
        // Orange emission: red + green contribution while penalising UV-blue.
        return r + 0.45 * g - 0.65 * b;
      case InkMode.diasf:
        // Cyan emission is separated from blue excitation mainly by green content.
        return g - 0.25 * r + 0.10 * b;
      case InkMode.auto:
        return g;
    }
  }

  double _otsu(List<double> values) {
    final sorted = List<double>.from(values)..sort();
    final low = _percentileSorted(sorted, 0.01);
    final high = _percentileSorted(sorted, 0.99);
    if (high <= low) return (high + low) / 2.0;

    final hist = List<int>.filled(256, 0);
    for (final v in values) {
      final scaled = (((v - low) / (high - low)) * 255.0).clamp(0.0, 255.0).round();
      hist[scaled]++;
    }

    final total = values.length;
    var sumTotal = 0.0;
    for (var i = 0; i < 256; i++) {
      sumTotal += i * hist[i];
    }

    var weightB = 0;
    var sumB = 0.0;
    var maxVariance = -1.0;
    var best = 127;

    for (var t = 0; t < 256; t++) {
      weightB += hist[t];
      if (weightB == 0) continue;
      final weightF = total - weightB;
      if (weightF == 0) break;

      sumB += t * hist[t];
      final meanB = sumB / weightB;
      final meanF = (sumTotal - sumB) / weightF;
      final variance = weightB * weightF * math.pow(meanB - meanF, 2).toDouble();
      if (variance > maxVariance) {
        maxVariance = variance;
        best = t;
      }
    }

    return low + (high - low) * best / 255.0;
  }

  double _percentileSorted(List<double> sorted, double fraction) {
    if (sorted.isEmpty) return 0.0;
    final index = ((sorted.length - 1) * fraction)
        .round()
        .clamp(0, sorted.length - 1)
        .toInt();
    return sorted[index];
  }

  List<bool> _repairShortRuns(List<bool> input) {
    if (input.length < 10) return input;
    final bits = List<bool>.from(input);
    final minRun = math.max(1, bits.length ~/ 520);

    var start = 0;
    while (start < bits.length) {
      var end = start + 1;
      while (end < bits.length && bits[end] == bits[start]) {
        end++;
      }
      final length = end - start;
      if (length <= minRun && start > 0 && end < bits.length) {
        final left = bits[start - 1];
        final right = bits[end];
        if (left == right) {
          for (var i = start; i < end; i++) {
            bits[i] = left;
          }
        }
      }
      start = end;
    }
    return bits;
  }

  String? _reconstructBarcode(List<bool> bits) {
    var first = -1;
    var last = -1;
    for (var i = 0; i < bits.length; i++) {
      if (bits[i]) {
        first = i;
        break;
      }
    }
    for (var i = bits.length - 1; i >= 0; i--) {
      if (bits[i]) {
        last = i;
        break;
      }
    }
    if (first < 0 || last <= first) return null;

    final barcodeWidth = last - first + 1;
    if (barcodeWidth < 80) return null;

    final quiet = math.max(24, barcodeWidth ~/ 10);
    const scale = 3;
    const outHeight = 180;
    final outWidth = (barcodeWidth + 2 * quiet) * scale;

    final out = html.CanvasElement(width: outWidth, height: outHeight);
    final ctx = out.context2D;
    ctx
      ..fillStyle = '#FFFFFF'
      ..fillRect(0, 0, outWidth, outHeight)
      ..fillStyle = '#000000';

    for (var i = first; i <= last; i++) {
      if (bits[i]) {
        final x = (quiet + i - first) * scale;
        ctx.fillRect(x, 0, scale, outHeight);
      }
    }
    return out.toDataUrl('image/png');
  }

  Future<(String, String)?> _decodeWithZxing(String dataUrl) async {
    try {
      final promise = js.context.callMethod('decodeCode128DataUrl', [dataUrl]);
      final dynamic raw = await js_util.promiseToFuture<dynamic>(promise);
      if (raw == null) return null;
      final map = jsonDecode(raw.toString()) as Map<String, dynamic>;
      return (
        (map['text'] ?? '').toString(),
        (map['format'] ?? 'Code 128').toString(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final compact = width < 760;

    return Scaffold(
      appBar: AppBar(
        title: const Text('FluoScan'),
        centerTitle: false,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Fluorescent barcode reader',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'The camera first tries the barcode inside the guide directly. If that fails, FluoScan isolates the luminogen emission, reconstructs a black/white barcode, and retries decoding.',
                  ),
                  const SizedBox(height: 16),
                  _modeSelector(),
                  const SizedBox(height: 14),
                  _cameraPanel(compact),
                  const SizedBox(height: 14),
                  _controls(compact),
                  const SizedBox(height: 10),
                  _scanStatusCard(),
                  const SizedBox(height: 12),
                  _sensitivityControl(),
                  const SizedBox(height: 14),
                  _resultCard(),
                  const SizedBox(height: 14),
                  _sampleCard(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _modeSelector() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: InkMode.values.map((mode) {
        return ChoiceChip(
          label: Text(mode.label),
          selected: _mode == mode,
          onSelected: (_) => setState(() => _mode = mode),
        );
      }).toList(),
    );
  }

  Widget _cameraPanel(bool compact) {
    return AspectRatio(
      aspectRatio: compact ? 4 / 3 : 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: const Color(0xFF05070B)),
            if (_cameraRunning)
              const HtmlElementView(viewType: _cameraViewType)
            else
              const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.camera_alt_outlined, color: Colors.white70, size: 42),
                    SizedBox(height: 8),
                    Text('Camera preview', style: TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.center,
              child: FractionallySizedBox(
                widthFactor: 0.90,
                heightFactor: 0.42,
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ),
            const Positioned(
              left: 18,
              bottom: 12,
              child: Text(
                'Keep ONE barcode horizontal inside the guide',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls(bool compact) {
    final buttons = <Widget>[
      FilledButton.icon(
        onPressed: _cameraRunning ? _stopCamera : _startCamera,
        icon: Icon(_cameraRunning ? Icons.stop_circle_outlined : Icons.videocam_outlined),
        label: Text(_cameraRunning ? 'Stop camera' : 'Start camera'),
      ),
      FilledButton.tonalIcon(
        onPressed: _cameraRunning && !_busy ? () => _scanCameraFrame() : null,
        icon: const Icon(Icons.document_scanner_outlined),
        label: const Text('Scan frame'),
      ),
      OutlinedButton.icon(
        onPressed: _busy ? null : _chooseImage,
        icon: const Icon(Icons.image_outlined),
        label: const Text('Choose image'),
      ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: _autoScan,
            onChanged: _cameraRunning
                ? (v) {
                    setState(() => _autoScan = v);
                    _restartAutoTimer();
                  }
                : null,
          ),
          const Text('Auto scan'),
        ],
      ),
    ];

    if (compact) {
      return Wrap(spacing: 8, runSpacing: 8, children: buttons);
    }
    return Row(
      children: [
        ...buttons.expand((w) => [w, const SizedBox(width: 8)]),
      ],
    );
  }

  Widget _scanStatusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (_busy) ...[
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(child: Text(_status)),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sensitivityControl() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Threshold sensitivity: ${_sensitivity.toStringAsFixed(2)}'),
            Slider(
              value: _sensitivity,
              min: -0.25,
              max: 0.25,
              divisions: 20,
              onChanged: (v) => setState(() => _sensitivity = v),
            ),
            const Text(
              'Leave at 0.00 initially. Move negative if weak bars disappear; move positive if fluorescent background/speckle is being interpreted as bars.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Decoded result', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SelectableText(
              _decoded,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            if (_details.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(_details, style: const TextStyle(color: Colors.black54)),
            ],
            if (_capturedRoiPng != null) ...[
              const SizedBox(height: 14),
              const Text('Captured guide region'),
              const SizedBox(height: 6),
              Container(
                color: Colors.black,
                padding: const EdgeInsets.all(6),
                child: Image.memory(_capturedRoiPng!, fit: BoxFit.contain),
              ),
            ],
            if (_processedPng != null) ...[
              const SizedBox(height: 14),
              const Text('Reconstructed barcode sent to decoder'),
              const SizedBox(height: 6),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: Image.memory(_processedPng!, fit: BoxFit.contain),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sampleCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Built-in test images', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text('Use these before testing the physical print. They are cropped from the barcode image supplied in this project.'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : () => _loadSample('samples/DiABP.png', InkMode.diabp),
                  child: const Text('Test DiABP'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _loadSample('samples/DiANBP.png', InkMode.dianbp),
                  child: const Text('Test DiANBP'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _loadSample('samples/DiASF.png', InkMode.diasf),
                  child: const Text('Test DiASF'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

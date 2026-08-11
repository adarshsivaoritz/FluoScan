// FluoScan v0.4
// Camera-only Flutter Web Code 128 reader tuned for fluorescent barcode
// photographs displayed on a monitor and scanned with a phone rear camera.

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:js_util' as js_util;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

void main() => runApp(const FluoScanApp());

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

class _DecodeResult {
  final String text;
  final String method;
  final double score;
  final List<bool>? bits;

  const _DecodeResult({
    required this.text,
    required this.method,
    required this.score,
    this.bits,
  });
}

class _ReconCandidate {
  final double score;
  final String label;
  final List<bool> bits;

  const _ReconCandidate(this.score, this.label, this.bits);
}

class _Run {
  final bool bar;
  final int width;
  const _Run(this.bar, this.width);
}

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  static const String _cameraViewType = 'fluoscan-camera-screen-v04';

  late final html.VideoElement _video;
  final html.CanvasElement _sourceCanvas = html.CanvasElement();
  html.MediaStream? _stream;
  Timer? _autoTimer;

  bool _cameraRunning = false;
  bool _autoScan = false;
  bool _busy = false;

  String _status = 'Ready. Start the rear camera and point it at the barcode shown on your screen.';
  String _decoded = '--';
  String _details = '';
  Uint8List? _capturedRoiPng;
  Uint8List? _processedPng;

  // Code 128 symbol width patterns, values 0..106.
  // 0..105 contain six alternating bar/space widths (11 modules total).
  // 106 is the stop pattern with seven widths (13 modules total).
  static const List<String> _code128Patterns = <String>[
    '212222','222122','222221','121223','121322','131222','122213','122312','132212','221213',
    '221312','231212','112232','122132','122231','113222','123122','123221','223211','221132',
    '221231','213212','223112','312131','311222','321122','321221','312212','322112','322211',
    '212123','212321','232121','111323','131123','131321','112313','132113','132311','211313',
    '231113','231311','112133','112331','132131','113123','113321','133121','313121','211331',
    '231131','213113','213311','213131','311123','311321','331121','312113','312311','332111',
    '314111','221411','431111','111224','111422','121124','121421','141122','141221','112214',
    '112412','122114','122411','142112','142211','241211','221114','413111','241112','134111',
    '111242','121142','121241','114212','124112','124211','411212','421112','421211','212141',
    '214121','412121','111143','111341','131141','114113','114311','411113','411311','113141',
    '114131','311141','411131','211412','211214','211232','2331112',
  ];

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
      setState(() => _status = 'Requesting rear-camera permission…');
      final mediaDevices = html.window.navigator.mediaDevices;
      final stream = await mediaDevices!.getUserMedia({
        'video': {
          'facingMode': {'ideal': 'environment'},
          'width': {'ideal': 1920},
          'height': {'ideal': 1080},
        },
        'audio': false,
      });

      _stream = stream;
      _video.srcObject = stream;
      await _video.play();
      if (!mounted) return;
      setState(() {
        _cameraRunning = true;
        _status = 'Camera ready. Fill most of the guide width with one horizontal barcode displayed on the screen.';
      });
      _restartAutoTimer();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Camera error: $e');
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
    _autoTimer = Timer.periodic(const Duration(milliseconds: 1400), (_) {
      if (!_busy) _scanCameraFrame(quiet: true);
    });
  }

  Future<void> _scanCameraFrame({bool quiet = false}) async {
    if (!_cameraRunning) {
      if (!quiet) setState(() => _status = 'Start the camera first.');
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
    final roi = _cameraGuideRect(w, h);
    await _analyseCanvas(
      _sourceCanvas,
      quiet: quiet,
      roiX: roi.left,
      roiY: roi.top,
      roiWidth: roi.width,
      roiHeight: roi.height,
    );
  }

  math.Rectangle<int> _cameraGuideRect(int sourceWidth, int sourceHeight) {
    final displayWidth = _video.clientWidth > 0 ? _video.clientWidth.toDouble() : sourceWidth.toDouble();
    final displayHeight = _video.clientHeight > 0 ? _video.clientHeight.toDouble() : sourceHeight.toDouble();

    final scale = math.max(displayWidth / sourceWidth, displayHeight / sourceHeight);
    final renderedWidth = sourceWidth * scale;
    final renderedHeight = sourceHeight * scale;
    final offsetX = (displayWidth - renderedWidth) / 2.0;
    final offsetY = (displayHeight - renderedHeight) / 2.0;

    // Must match the FractionallySizedBox in _cameraPanel.
    const guideWidthFactor = 0.92;
    const guideHeightFactor = 0.36;
    final guideLeft = displayWidth * ((1.0 - guideWidthFactor) / 2.0);
    final guideTop = displayHeight * (0.50 - guideHeightFactor / 2.0);
    final guideWidth = displayWidth * guideWidthFactor;
    final guideHeight = displayHeight * guideHeightFactor;

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

  Future<void> _analyseCanvas(
    html.CanvasElement canvas, {
    bool quiet = false,
    int roiX = 0,
    int roiY = 0,
    int? roiWidth,
    int? roiHeight,
  }) async {
    if (_busy) return;
    _busy = true;
    if (mounted && !quiet) {
      setState(() {
        _status = 'Scanning screen image…';
        _decoded = '--';
        _details = '';
      });
    }

    try {
      final fullWidth = canvas.width ?? 0;
      final fullHeight = canvas.height ?? 0;
      if (fullWidth < 160 || fullHeight < 60) throw 'Camera frame is too small.';

      final x = roiX.clamp(0, fullWidth - 1).toInt();
      final y = roiY.clamp(0, fullHeight - 1).toInt();
      final width = (roiWidth ?? (fullWidth - x)).clamp(1, fullWidth - x).toInt();
      final height = (roiHeight ?? (fullHeight - y)).clamp(1, fullHeight - y).toInt();
      if (width < 160 || height < 40) throw 'Barcode guide region is too small.';

      final roiData = canvas.context2D.getImageData(x, y, width, height);
      final roiCanvas = html.CanvasElement(width: width, height: height);
      roiCanvas.context2D.putImageData(roiData, 0, 0);
      final roiDataUrl = roiCanvas.toDataUrl('image/png');
      final roiRaw = roiDataUrl.split(',').last;
      if (mounted) setState(() => _capturedRoiPng = base64Decode(roiRaw));

      // 1) Let the browser/ZXing try the actual guide image first.
      final direct = await _decodeWithBrowser(roiDataUrl);
      if (direct != null && direct.$1.trim().isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _decoded = direct.$1;
          _details = 'Direct guide decode • ${direct.$2}';
          _processedPng = null;
          _status = 'Decoded successfully.';
        });
        return;
      }

      // 2) Screen-specific 1D analysis. Instead of trusting one threshold,
      // v0.4 tries several colour/luminance profiles, several horizontal
      // bands and several thresholds. A custom Code 128 run-width decoder
      // validates the checksum, which is more tolerant of screen moire than
      // asking ZXing to infer everything from the raw fluorescent image.
      final pixels = roiData.data;
      const bands = <double>[0.28, 0.36, 0.43, 0.50, 0.57, 0.64, 0.72];
      const thresholdLevels = <double>[0.34, 0.40, 0.46, 0.52, 0.58, 0.64, 0.70, 0.76];
      const profileKinds = <String>['LUMA', 'GREEN', 'G-B', 'ORANGE', 'CYAN'];

      _DecodeResult? bestDecoded;
      final bestRecon = <_ReconCandidate>[];

      for (final kind in profileKinds) {
        if (bestDecoded != null) break;
        for (final band in bands) {
          final raw = _extractScreenProfile(pixels, width, height, band, kind);
          if (raw.length < 120) continue;

          final variants = <(String, List<double>)>[
            ('raw', raw),
            ('smooth', _smoothProfile(raw)),
          ];

          for (final variant in variants) {
            final normalized = _robustNormalize(variant.$2);
            if (normalized == null) continue;

            for (final level in thresholdLevels) {
              // Fluorescent bars on the displayed photographs are expected
              // to be brighter than the background. Dark polarity is kept as
              // a compact fallback for conventional-looking screen images.
              for (var polarity = 0; polarity < 2; polarity++) {
                var bits = normalized.map((v) => polarity == 0 ? v >= level : v < level).toList(growable: false);
                bits = _removeSinglePixelGlitches(bits);

                final label = '$kind/${variant.$1} • band ${(band * 100).round()}% • level ${level.toStringAsFixed(2)} • ${polarity == 0 ? 'bright' : 'dark'} bars';
                final decoded = _decodeCode128Runs(bits, label);
                final structureScore = _quickStructureScore(bits);
                if (structureScore.isFinite) {
                  _keepBestRecon(bestRecon, _ReconCandidate(structureScore, label, bits));
                }

                if (decoded != null) {
                  bestDecoded = decoded;
                  break;
                }
              }
              if (bestDecoded != null) break;
            }
            if (bestDecoded != null) break;
          }
          if (bestDecoded != null) break;
        }
      }

      if (bestDecoded != null) {
        final reconstructed = _reconstructBarcode(bestDecoded.bits!);
        if (!mounted) return;
        setState(() {
          _decoded = bestDecoded!.text;
          _details = '${bestDecoded!.method} • checksum valid • structural score ${bestDecoded!.score.toStringAsFixed(2)}';
          _processedPng = reconstructed == null ? null : base64Decode(reconstructed.split(',').last);
          _status = 'Decoded successfully.';
        });
        return;
      }

      // 3) Custom decoder did not validate a checksum. Give ZXing/native
      // detector the best few reconstructed candidates rather than hundreds
      // of threshold variants. This keeps scanning responsive on a phone.
      for (final candidate in bestRecon.take(5)) {
        final reconstructed = _reconstructBarcode(candidate.bits);
        if (reconstructed == null) continue;
        final zxing = await _decodeWithBrowser(reconstructed);
        if (zxing != null && zxing.$1.trim().isNotEmpty) {
          if (!mounted) return;
          setState(() {
            _decoded = zxing.$1;
            _details = '${zxing.$2} after screen reconstruction • ${candidate.label}';
            _processedPng = base64Decode(reconstructed.split(',').last);
            _status = 'Decoded successfully.';
          });
          return;
        }
      }

      if (!quiet && mounted) {
        Uint8List? diagnostic;
        String detail = 'No barcode-like reconstruction was found.';
        if (bestRecon.isNotEmpty) {
          final reconstructed = _reconstructBarcode(bestRecon.first.bits);
          if (reconstructed != null) diagnostic = base64Decode(reconstructed.split(',').last);
          detail = 'Best reconstruction: ${bestRecon.first.label} • structural score ${bestRecon.first.score.toStringAsFixed(2)}';
        }
        setState(() {
          _decoded = '--';
          _details = detail;
          _processedPng = diagnostic;
          _status = 'No checksum-valid Code 128 result. Use the captured region and best reconstruction below for tuning.';
        });
      }
    } catch (e) {
      if (!quiet && mounted) setState(() => _status = 'Processing error: $e');
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  List<double> _extractScreenProfile(
    Uint8ClampedList pixels,
    int width,
    int height,
    double bandFraction,
    String kind,
  ) {
    // Keep the full quiet zone while dropping only a tiny outer margin.
    final x0 = (width * 0.01).round();
    final x1 = (width * 0.99).round();
    final centreY = (height * bandFraction).round();
    final halfThickness = math.max(2, height ~/ 40);
    final y0 = math.max(0, centreY - halfThickness);
    final y1 = math.min(height - 1, centreY + halfThickness);

    final profile = List<double>.filled(x1 - x0, 0.0);
    for (var x = x0; x < x1; x++) {
      final samples = <double>[];
      for (var y = y0; y <= y1; y++) {
        final i = (y * width + x) * 4;
        final r = pixels[i].toDouble();
        final g = pixels[i + 1].toDouble();
        final b = pixels[i + 2].toDouble();
        switch (kind) {
          case 'GREEN':
            samples.add(g);
            break;
          case 'G-B':
            samples.add(g + 0.10 * r - 0.72 * b);
            break;
          case 'ORANGE':
            samples.add(r + 0.45 * g - 0.65 * b);
            break;
          case 'CYAN':
            samples.add(g + 0.20 * b - 0.25 * r);
            break;
          case 'LUMA':
          default:
            samples.add(0.2126 * r + 0.7152 * g + 0.0722 * b);
        }
      }
      // Median across a vertical strip rejects monitor sub-pixel texture,
      // scan-line banding and isolated bright/dark screen pixels better than
      // a single horizontal line.
      samples.sort();
      profile[x - x0] = samples[samples.length ~/ 2];
    }
    return profile;
  }

  List<double> _smoothProfile(List<double> input) {
    if (input.length < 5) return List<double>.from(input);
    final out = List<double>.from(input);
    // Small symmetric filter: enough to suppress screen pixel structure,
    // deliberately weak enough to preserve narrow Code 128 modules.
    for (var i = 2; i < input.length - 2; i++) {
      out[i] = (input[i - 2] + 2 * input[i - 1] + 3 * input[i] + 2 * input[i + 1] + input[i + 2]) / 9.0;
    }
    return out;
  }

  List<double>? _robustNormalize(List<double> profile) {
    final sorted = List<double>.from(profile)..sort();
    final low = _percentileSorted(sorted, 0.02);
    final high = _percentileSorted(sorted, 0.98);
    final span = high - low;
    if (span.abs() < 2.0) return null;
    return profile.map((v) => ((v - low) / span).clamp(0.0, 1.0)).toList(growable: false);
  }

  double _percentileSorted(List<double> sorted, double fraction) {
    if (sorted.isEmpty) return 0.0;
    final index = ((sorted.length - 1) * fraction).round().clamp(0, sorted.length - 1).toInt();
    return sorted[index];
  }

  List<bool> _removeSinglePixelGlitches(List<bool> input) {
    if (input.length < 3) return input;
    final out = List<bool>.from(input);
    for (var i = 1; i < input.length - 1; i++) {
      if (input[i - 1] == input[i + 1] && input[i] != input[i - 1]) {
        out[i] = input[i - 1];
      }
    }
    return out;
  }

  List<_Run> _runsFromBits(List<bool> bits) {
    var first = bits.indexWhere((v) => v);
    if (first < 0) return const <_Run>[];
    var last = bits.length - 1;
    while (last >= first && !bits[last]) last--;
    if (last <= first) return const <_Run>[];

    final runs = <_Run>[];
    var current = bits[first];
    var width = 1;
    for (var i = first + 1; i <= last; i++) {
      if (bits[i] == current) {
        width++;
      } else {
        runs.add(_Run(current, width));
        current = bits[i];
        width = 1;
      }
    }
    runs.add(_Run(current, width));
    return runs;
  }

  _DecodeResult? _decodeCode128Runs(List<bool> bits, String methodLabel) {
    final allRuns = _runsFromBits(bits);
    if (allRuns.length < 25) return null;

    _DecodeResult? best;
    // Trimming by pairs preserves the expected bar/space alternation and
    // handles small bright objects or cursor fragments at the ROI edges.
    for (final startCut in <int>[0, 2, 4, 6, 8]) {
      for (final endCut in <int>[0, 2, 4, 6, 8]) {
        final end = allRuns.length - endCut;
        if (startCut >= end) continue;
        final runs = allRuns.sublist(startCut, end);
        if (runs.length < 25 || runs.length % 6 != 1) continue;
        if (!runs.first.bar || !runs.last.bar) continue;

        final symbolCount = (runs.length - 7) ~/ 6;
        if (symbolCount < 3) continue; // start + checksum + at least one data symbol

        final values = <int>[];
        var totalScore = 0.0;
        var valid = true;

        // Start symbol: only 103,104,105 are legal.
        final startMatch = _bestPattern(runs.sublist(0, 6), const [103, 104, 105]);
        if (startMatch == null || startMatch.$2 > 0.82) continue;
        values.add(startMatch.$1);
        totalScore += startMatch.$2;

        for (var s = 1; s < symbolCount; s++) {
          final group = runs.sublist(s * 6, s * 6 + 6);
          final match = _bestPattern(group, List<int>.generate(103, (i) => i));
          if (match == null || match.$2 > 0.95) {
            valid = false;
            break;
          }
          values.add(match.$1);
          totalScore += match.$2;
        }
        if (!valid || values.length < 3) continue;

        final stopRuns = runs.sublist(symbolCount * 6);
        final stopScore = _patternCost(stopRuns, _patternWidths(106));
        if (!stopScore.isFinite || stopScore > 0.95) continue;
        totalScore += stopScore;

        final checksumValue = values.last;
        var checksum = values.first;
        for (var i = 1; i < values.length - 1; i++) {
          checksum += values[i] * i;
        }
        if (checksum % 103 != checksumValue) continue;

        final text = _decodeCode128Values(values);
        if (text == null || text.isEmpty) continue;

        final avgScore = totalScore / (values.length + 1);
        final candidate = _DecodeResult(
          text: text,
          method: 'Code 128 screen-profile • $methodLabel',
          score: avgScore,
          bits: bits,
        );
        if (best == null || candidate.score < best.score) best = candidate;
      }
    }
    return best;
  }

  (int, double)? _bestPattern(List<_Run> runs, List<int> allowed) {
    if (runs.length != 6) return null;
    int? bestValue;
    var bestScore = double.infinity;
    for (final value in allowed) {
      final score = _patternCost(runs, _patternWidths(value));
      if (score < bestScore) {
        bestScore = score;
        bestValue = value;
      }
    }
    return bestValue == null ? null : (bestValue, bestScore);
  }

  List<int> _patternWidths(int value) {
    return _code128Patterns[value].split('').map(int.parse).toList(growable: false);
  }

  double _patternCost(List<_Run> runs, List<int> pattern) {
    if (runs.length != pattern.length || runs.isEmpty) return double.infinity;
    final actualSum = runs.fold<int>(0, (sum, r) => sum + r.width);
    final moduleSum = pattern.fold<int>(0, (sum, v) => sum + v);
    if (actualSum <= 0 || moduleSum <= 0) return double.infinity;
    final scale = actualSum / moduleSum;
    if (scale <= 0.1) return double.infinity;

    var cost = 0.0;
    for (var i = 0; i < runs.length; i++) {
      final modules = runs[i].width / scale;
      cost += (modules - pattern[i]).abs();
    }
    return cost / runs.length;
  }

  String? _decodeCode128Values(List<int> values) {
    if (values.length < 3) return null;
    var set = switch (values.first) {
      103 => 'A',
      104 => 'B',
      105 => 'C',
      _ => '',
    };
    if (set.isEmpty) return null;

    final out = StringBuffer();
    var shift = false;
    // Exclude start and checksum values.
    for (var i = 1; i < values.length - 1; i++) {
      final v = values[i];

      // Code-set switches are controls only when they are controls in the
      // current set. In Code C, values 00..99 are numeric data.
      if (set != 'C' && v == 99) {
        set = 'C';
        shift = false;
        continue;
      }
      if (set != 'B' && v == 100) {
        set = 'B';
        shift = false;
        continue;
      }
      if (set != 'A' && v == 101) {
        set = 'A';
        shift = false;
        continue;
      }
      if (set != 'C' && v == 98) {
        shift = true;
        continue;
      }

      var activeSet = set;
      if (shift) {
        activeSet = set == 'A' ? 'B' : 'A';
        shift = false;
      }

      if (activeSet == 'C') {
        if (v > 99) {
          // FNC1 (102) can occur in Code C; these experimental labels do not
          // use it, so ignore it without adding invented text.
          if (v == 102) continue;
          return null;
        }
        out.write(v.toString().padLeft(2, '0'));
      } else if (activeSet == 'B') {
        if (v > 95) {
          // FNC/control symbols are not expected in the current labels.
          continue;
        }
        out.writeCharCode(v + 32);
      } else if (activeSet == 'A') {
        if (v <= 63) {
          out.writeCharCode(v + 32);
        } else if (v <= 95) {
          out.writeCharCode(v - 64);
        } else {
          return null;
        }
      }
    }
    return out.toString();
  }

  double _quickStructureScore(List<bool> bits) {
    final allRuns = _runsFromBits(bits);
    if (allRuns.length < 25) return double.infinity;
    var best = double.infinity;
    for (final startCut in <int>[0, 2, 4, 6, 8]) {
      for (final endCut in <int>[0, 2, 4, 6, 8]) {
        final end = allRuns.length - endCut;
        if (startCut >= end) continue;
        final runs = allRuns.sublist(startCut, end);
        if (runs.length < 25 || runs.length % 6 != 1) continue;
        final symbolCount = (runs.length - 7) ~/ 6;
        if (symbolCount < 3) continue;
        final start = _bestPattern(runs.sublist(0, 6), const [103, 104, 105]);
        if (start == null) continue;
        final stop = _patternCost(runs.sublist(symbolCount * 6), _patternWidths(106));
        final score = start.$2 + stop;
        if (score < best) best = score;
      }
    }
    return best;
  }

  void _keepBestRecon(List<_ReconCandidate> list, _ReconCandidate candidate) {
    list.add(candidate);
    list.sort((a, b) => a.score.compareTo(b.score));
    if (list.length > 8) list.removeRange(8, list.length);
  }

  String? _reconstructBarcode(List<bool> bits) {
    var first = bits.indexWhere((v) => v);
    if (first < 0) return null;
    var last = bits.length - 1;
    while (last >= first && !bits[last]) last--;
    if (last <= first) return null;

    final barcodeWidth = last - first + 1;
    if (barcodeWidth < 80) return null;
    final quiet = math.max(28, barcodeWidth ~/ 8);
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

  Future<(String, String)?> _decodeWithBrowser(String dataUrl) async {
    try {
      final promise = js.context.callMethod('decodeCode128DataUrl', [dataUrl]);
      final dynamic raw = await js_util.promiseToFuture<dynamic>(promise);
      if (raw == null) return null;
      final map = jsonDecode(raw.toString()) as Map<String, dynamic>;
      return ((map['text'] ?? '').toString(), (map['format'] ?? 'Code 128').toString());
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.of(context).size.width < 760;
    return Scaffold(
      appBar: AppBar(title: const Text('FluoScan')),
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
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'The camera sees the visible fluorescence. FluoScan isolates the luminogen emission, reconstructs a conventional black/white barcode, and then attempts Code 128 decoding.',
                  ),
                  const SizedBox(height: 14),
                  _cameraPanel(compact),
                  const SizedBox(height: 14),
                  _controls(compact),
                  const SizedBox(height: 10),
                  _scanStatusCard(),
                  const SizedBox(height: 14),
                  _resultCard(),
                  const SizedBox(height: 12),
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(14),
                      child: Text(
                        'Keep one barcode horizontal inside the guide and hold the phone as square to the barcode as possible.',
                        style: TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
                    Text('Rear-camera preview', style: TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.center,
              child: FractionallySizedBox(
                widthFactor: 0.92,
                heightFactor: 0.36,
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
                'One horizontal barcode • include blank space at both ends',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls(bool compact) {
    final controls = <Widget>[
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

    if (compact) return Wrap(spacing: 8, runSpacing: 8, children: controls);
    return Row(children: controls.expand((w) => [w, const SizedBox(width: 8)]).toList());
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
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
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

  Widget _resultCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Decoded result', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SelectableText(_decoded, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
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
              const Text('Best reconstructed barcode'),
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
}

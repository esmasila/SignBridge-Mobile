// Faz B: ONNX Runtime ile GRU'yu telefonda calistir.
//
// Kullanim:
//   final inf = LocalInference();
//   await inf.init();
//   final result = await inf.predict(modelInput);  // Float32List 30*1755
//   // result.label, result.confidence, result.margin
//
// Model shape: input=[1,30,1755], logits=[1,100]
// Asset: assets/model/model_v2.onnx + assets/model/label_map.json

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

class InferenceResult {
  final String label;
  final double confidence;   // softmax(top-1)
  final double margin;       // softmax(top-1) - softmax(top-2)
  /// Top-3 aday: [(label, prob), ...]. [0] = top-1. Debug / confusion logging icin.
  final List<MapEntry<String, double>> topK;

  InferenceResult(this.label, this.confidence, this.margin, this.topK);

  String get topKString => topK
      .map((e) => '${e.key} ${(e.value * 100).toStringAsFixed(0)}%')
      .join(' | ');

  @override
  String toString() => '$label (${(confidence * 100).toStringAsFixed(1)}%)';
}

class LocalInference {
  OrtSession? _session;
  OrtSessionOptions? _options;
  List<String>? _idxToLabel;
  bool _initialized = false;
  bool get ready => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    try {
      OrtEnv.instance.init();
      _options = OrtSessionOptions()
        ..setInterOpNumThreads(2)
        ..setIntraOpNumThreads(2)
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

      // Model asset yukle
      final modelBytes = await rootBundle.load('assets/model/model_v2.onnx');
      final bytes = modelBytes.buffer.asUint8List();
      _session = OrtSession.fromBuffer(bytes, _options!);

      // Label map yukle: {"LABEL": idx, ...} -> List<String> idx->label
      final labelJson = await rootBundle.loadString('assets/model/label_map.json');
      final Map<String, dynamic> labelMap = jsonDecode(labelJson);
      final numClasses = labelMap.length;
      final arr = List<String>.filled(numClasses, '');
      labelMap.forEach((k, v) { arr[v as int] = k; });
      _idxToLabel = arr;

      _initialized = true;
    } catch (e) {
      _initialized = false;
      rethrow;
    }
  }

  /// [input] beklenen shape: [1, 30, 1755] duzlestirilmis Float32List (52650).
  /// Ucuncu arguman runAsync kullanir ki UI donmasin.
  Future<InferenceResult?> predict(Float32List input) async {
    if (!_initialized || _session == null || _idxToLabel == null) return null;

    // Beklenen uzunluk: 1 * 30 * 1755 = 52650
    const expected = 1 * 30 * 1755;
    if (input.length != expected) {
      throw ArgumentError('Beklenen giriş uzunluğu $expected, gelen ${input.length}');
    }

    OrtValueTensor? inputTensor;
    OrtRunOptions? runOptions;
    List<OrtValue?>? outputs;
    try {
      inputTensor = OrtValueTensor.createTensorWithDataList(input, [1, 30, 1755]);
      runOptions = OrtRunOptions();
      outputs = await _session!.runAsync(runOptions, {'input': inputTensor});
      if (outputs == null || outputs.isEmpty || outputs[0] == null) return null;

      final raw = outputs[0]!.value;
      // Beklenen: List<List<double>> shape [1, 100]
      if (raw is! List) return null;
      final row0 = raw[0];
      if (row0 is! List) return null;
      final logits = List<double>.from(row0.map((e) => (e as num).toDouble()));

      // Softmax
      double maxLog = logits[0];
      for (final v in logits) { if (v > maxLog) maxLog = v; }
      double sum = 0.0;
      final probs = List<double>.filled(logits.length, 0.0);
      for (int i = 0; i < logits.length; i++) {
        final e = math.exp(logits[i] - maxLog);
        probs[i] = e;
        sum += e;
      }
      for (int i = 0; i < probs.length; i++) {
        probs[i] /= sum;
      }

      // Top-3: confusion matrix gorebilmek icin
      const k = 3;
      final idxs = List<int>.generate(probs.length, (i) => i);
      idxs.sort((a, b) => probs[b].compareTo(probs[a]));
      final topK = <MapEntry<String, double>>[];
      for (int i = 0; i < k && i < idxs.length; i++) {
        final ix = idxs[i];
        final name = (ix >= 0 && ix < _idxToLabel!.length)
            ? _idxToLabel![ix] : 'UNKNOWN';
        topK.add(MapEntry(name, probs[ix]));
      }

      final p1 = topK.isNotEmpty ? topK[0].value : 0.0;
      final p2 = topK.length >= 2 ? topK[1].value : 0.0;
      final label = topK.isNotEmpty ? topK[0].key : 'UNKNOWN';
      final margin = p1 - p2;

      return InferenceResult(label, p1, margin, topK);
    } finally {
      inputTensor?.release();
      runOptions?.release();
      outputs?.forEach((v) => v?.release());
    }
  }

  void dispose() {
    _session?.release();
    _session = null;
    _options?.release();
    _options = null;
    // OrtEnv singleton — uygulama kapanana kadar acik bira.
    _initialized = false;
  }
}

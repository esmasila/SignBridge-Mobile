// Faz C: MediaPipe telefonda. Flutter camera plugin'den gelen CameraImage'i
// NV21 byte dizisine donustur, Android tarafina MethodChannel ile gonder,
// 1629-float landmark vektoru ve "el goruldu mu" bayragini geri al.
//
// Kullanim:
//   final mp = MpNative();
//   await mp.init();
//   final r = await mp.processCameraImage(image, rotation: 90, mirror: true);
//   // r.landmarks: Float32List(1629), r.handSeen: bool

import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

class MpResult {
  final Float32List landmarks;  // 1629 float
  final bool handSeen;
  MpResult(this.landmarks, this.handSeen);
}

class MpNative {
  static const MethodChannel _channel = MethodChannel('signbridge/mediapipe');

  bool _initialized = false;
  bool get ready => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    final ok = await _channel.invokeMethod<bool>('init');
    _initialized = ok == true;
  }

  Future<void> close() async {
    try { await _channel.invokeMethod('close'); } catch (_) {}
    _initialized = false;
  }

  /// CameraImage (YUV_420_888) -> NV21 -> native MediaPipe -> 1629 float
  Future<MpResult?> processCameraImage(
    CameraImage image, {
    required int rotation,
    required bool mirror,
  }) async {
    if (!_initialized) throw StateError('MpNative not initialized');

    // NV21 donusumu main thread'de (byte kopyalama, izolate overhead'ine degmez)
    final conv = _yuv420ToNv21(_YuvInput.fromCameraImage(image));

    // Hatalari yutma — caller .catchError ile goruyor.
    final result = await _channel.invokeMethod<Uint8List>('processNv21', {
      'bytes': conv,
      'width': image.width,
      'height': image.height,
      'rotation': rotation,
      'mirror': mirror,
    });
    if (result == null) {
      throw StateError('native returned null');
    }
    if (result.length < 4 + 1629 * 4) {
      throw StateError('native payload too small: ${result.length}');
    }

    // Byte duzeni: [flag, pad, pad, pad, 1629*float32...]
    // NOT: Flutter MethodChannel bazen offsetInBytes != 0 donuyor; +4 header
    //      offsetini 4-byte aligned olmaktan cikariyor. Float32List.view buna
    //      tahammulsuz, ByteData tahammullu.
    final handSeen = result[0] == 1;
    final bd = ByteData.sublistView(result, 4);
    final lm = Float32List(1629);
    for (int i = 0; i < 1629; i++) {
      lm[i] = bd.getFloat32(i * 4, Endian.little);
    }
    return MpResult(lm, handSeen);
  }
}

// ────────────────────────── YUV_420_888 -> NV21 ──────────────────────────

class _YuvInput {
  final int width;
  final int height;
  final Uint8List y;
  final Uint8List u;
  final Uint8List v;
  final int yRowStride;
  final int uRowStride;
  final int vRowStride;
  final int uPixelStride;
  final int vPixelStride;

  _YuvInput({
    required this.width,
    required this.height,
    required this.y,
    required this.u,
    required this.v,
    required this.yRowStride,
    required this.uRowStride,
    required this.vRowStride,
    required this.uPixelStride,
    required this.vPixelStride,
  });

  factory _YuvInput.fromCameraImage(CameraImage image) {
    final yp = image.planes[0];
    final up = image.planes[1];
    final vp = image.planes[2];
    return _YuvInput(
      width: image.width,
      height: image.height,
      y: yp.bytes,
      u: up.bytes,
      v: vp.bytes,
      yRowStride: yp.bytesPerRow,
      uRowStride: up.bytesPerRow,
      vRowStride: vp.bytesPerRow,
      uPixelStride: up.bytesPerPixel ?? 1,
      vPixelStride: vp.bytesPerPixel ?? 1,
    );
  }
}

/// Android CameraImage YUV_420_888 -> NV21 (Y + interleaved VU)
/// Bu fonksiyon top-level olmali ki compute() icinde calissin.
Uint8List _yuv420ToNv21(_YuvInput inp) {
  final w = inp.width;
  final h = inp.height;
  final ySize = w * h;
  final uvSize = ySize ~/ 2;
  final out = Uint8List(ySize + uvSize);

  // ---- Y plane (stride'a dikkat) ----
  int dst = 0;
  if (inp.yRowStride == w) {
    out.setRange(0, ySize, inp.y);
    dst = ySize;
  } else {
    for (int row = 0; row < h; row++) {
      final src = row * inp.yRowStride;
      out.setRange(dst, dst + w, inp.y, src);
      dst += w;
    }
  }

  // ---- VU interleaved (NV21) ----
  final hh = h ~/ 2;
  final ww = w ~/ 2;
  for (int row = 0; row < hh; row++) {
    final uRow = row * inp.uRowStride;
    final vRow = row * inp.vRowStride;
    for (int col = 0; col < ww; col++) {
      out[dst++] = inp.v[vRow + col * inp.vPixelStride];
      out[dst++] = inp.u[uRow + col * inp.uPixelStride];
    }
  }

  return out;
}

// Faz A: Hizli YUV420 -> JPEG donusturucu (isolate icin)
//
// startImageStream() Android'de YUV420 planar veri verir. Bu dosyayi
// compute() ile cagirinca UI thread donmaz.
//
// NOT: iOS (BGRA8888) icin ayri yol var; Android yonelimi sensorOrientation'a
// gore 90° donduruyoruz. Sunucuya 320x? civari JPEG gonderiyoruz (MediaPipe
// icin yeterli; aga yuklenme ~5-10 KB/kare).

import 'dart:typed_data';
import 'package:image/image.dart' as img;

class FrameInput {
  final int width;
  final int height;
  final int yRowStride;
  final int uRowStride;
  final int uvPixelStride;
  final Uint8List yBytes;
  final Uint8List uBytes;
  final Uint8List vBytes;
  final int rotation;  // 0, 90, 180, 270
  final bool mirror;   // on kamera icin true
  final int jpegQuality;

  const FrameInput({
    required this.width,
    required this.height,
    required this.yRowStride,
    required this.uRowStride,
    required this.uvPixelStride,
    required this.yBytes,
    required this.uBytes,
    required this.vBytes,
    required this.rotation,
    required this.mirror,
    this.jpegQuality = 55,
  });
}

/// YUV420 -> RGB (2x downsample) -> donme/ayna -> JPEG
/// compute()/Isolate.run() icin entry point (pure function)
Uint8List encodeYuv420ToJpeg(FrameInput f) {
  final w = f.width;
  final h = f.height;
  // 2x downsample: resolution_low zaten 352x288 gibi; 176x144 MediaPipe icin
  // yetersiz kaliyor. Downsample kapatildi (tam cozunurlukte isliyoruz).
  const downsample = 1;
  final outW = w ~/ downsample;
  final outH = h ~/ downsample;

  final rgb = Uint8List(outW * outH * 3);
  int idx = 0;

  final yp = f.yBytes;
  final up = f.uBytes;
  final vp = f.vBytes;
  final yrs = f.yRowStride;
  final urs = f.uRowStride;
  final ups = f.uvPixelStride;

  // BT.601 sabitler (fixed-point 16-bit)
  // r = Y + 1.402*(V-128)
  // g = Y - 0.344*(U-128) - 0.714*(V-128)
  // b = Y + 1.772*(U-128)
  for (int py = 0; py < h; py += downsample) {
    for (int px = 0; px < w; px += downsample) {
      final yIdx = py * yrs + px;
      final uvIdx = (py >> 1) * urs + (px >> 1) * ups;

      final Y = yp[yIdx] & 0xff;
      final U = (up[uvIdx] & 0xff) - 128;
      final V = (vp[uvIdx] & 0xff) - 128;

      int r = Y + ((91881 * V) >> 16);
      int g = Y - ((22544 * U + 46793 * V) >> 16);
      int b = Y + ((116129 * U) >> 16);

      if (r < 0) r = 0; else if (r > 255) r = 255;
      if (g < 0) g = 0; else if (g > 255) g = 255;
      if (b < 0) b = 0; else if (b > 255) b = 255;

      rgb[idx++] = r;
      rgb[idx++] = g;
      rgb[idx++] = b;
    }
  }

  img.Image image = img.Image.fromBytes(
    width: outW,
    height: outH,
    bytes: rgb.buffer,
    numChannels: 3,
  );

  // Sensor yonu: Android telefonlarinda genelde 90° veya 270°.
  // startImageStream() sensor frame'ini ham verir — biz upright yapmaliyiz.
  if (f.rotation == 90) {
    image = img.copyRotate(image, angle: 90);
  } else if (f.rotation == 180) {
    image = img.copyRotate(image, angle: 180);
  } else if (f.rotation == 270) {
    image = img.copyRotate(image, angle: 270);
  }

  // On kamera ayna (mirror) — kullanicinin gordugu goruntuyle eslesir
  if (f.mirror) {
    image = img.flipHorizontal(image);
  }

  return Uint8List.fromList(img.encodeJpg(image, quality: f.jpegQuality));
}

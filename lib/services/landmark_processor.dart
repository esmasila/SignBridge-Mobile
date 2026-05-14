// Faz B: Python normalize_landmarks + add_velocity + clip + 30-frame buffer
//
// Sunucudan 1629 ham float32 landmark gelir. Bu dosya:
//   1) KATMAN 1: omuz-merkezli (pose[11]+pose[12] ortasini origin, omuz mesafesini scale alir)
//   2) KATMAN 2: sol/sag el bilek-merkezli (palm_scale ile)
//   3) 30-frame buffer tutar
//   4) Hands velocity ekler -> 1755
//   5) [-5, 5] clip
//
// Cikis: model_v2.onnx'e beslenecek Float32List (30*1755 = 52650 eleman)
//
// Python referans: experiment_v2/web_app.py::normalize_landmarks, add_velocity

import 'dart:math' as math;
import 'dart:typed_data';

class LandmarkLayout {
  // Python sabitleri
  static const int faceEnd  = 1404;  // 468*3
  static const int poseEnd  = 1503;  // faceEnd + 33*3
  static const int leftEnd  = 1566;  // poseEnd + 21*3
  static const int rightEnd = 1629;  // leftEnd + 21*3
  static const int handVel  = 126;   // 21*3 + 21*3
  static const int inputSize = rightEnd + handVel;  // 1755

  // Omuz indeksleri (pose 33 noktada)
  static const int leftShoulderIdx  = 11;   // => lm[faceEnd + 11*3 .. +2]
  static const int rightShoulderIdx = 12;   // => lm[faceEnd + 12*3 .. +2]

  // El noktalari (21 noktada)
  static const int wristIdx      = 0;        // bilek
  static const int middleBaseIdx = 9;        // orta parmak kok (palm scale)
}

class LandmarkProcessor {
  static const int seqLen = 30;

  final List<Float32List> _buffer = <Float32List>[];

  int get bufferSize => _buffer.length;
  bool get ready => _buffer.length == seqLen;

  void reset() => _buffer.clear();

  /// Python normalize_landmarks portu. 1629 ham -> 1629 normalize.
  /// In-place: gelen lm uzerinde calisir ve ayni referansi geri dondurur.
  static Float32List normalizeLandmarks(Float32List lm) {
    assert(lm.length == LandmarkLayout.rightEnd);

    // ---- KATMAN 1: Omuz-merkezli ----
    final ls0 = lm[LandmarkLayout.faceEnd + 11 * 3];
    final ls1 = lm[LandmarkLayout.faceEnd + 11 * 3 + 1];
    final ls2 = lm[LandmarkLayout.faceEnd + 11 * 3 + 2];
    final rs0 = lm[LandmarkLayout.faceEnd + 12 * 3];
    final rs1 = lm[LandmarkLayout.faceEnd + 12 * 3 + 1];
    final rs2 = lm[LandmarkLayout.faceEnd + 12 * 3 + 2];

    bool lsZero = _allZero3(ls0, ls1, ls2);
    bool rsZero = _allZero3(rs0, rs1, rs2);

    if (!(lsZero && rsZero)) {
      double cx, cy, cz;
      if (lsZero) {
        cx = rs0; cy = rs1; cz = rs2;
      } else if (rsZero) {
        cx = ls0; cy = ls1; cz = ls2;
      } else {
        cx = (ls0 + rs0) * 0.5;
        cy = (ls1 + rs1) * 0.5;
        cz = (ls2 + rs2) * 0.5;
      }
      final dx = rs0 - ls0, dy = rs1 - ls1, dz = rs2 - ls2;
      final scale = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (scale >= 1e-4) {
        // Tum 1629 landmark'i merkeze cek + olceklendir
        final inv = 1.0 / scale;
        for (int i = 0; i < LandmarkLayout.rightEnd; i += 3) {
          lm[i]     = (lm[i]     - cx) * inv;
          lm[i + 1] = (lm[i + 1] - cy) * inv;
          lm[i + 2] = (lm[i + 2] - cz) * inv;
        }
      }
    }

    // ---- KATMAN 2: Sol el bilek-merkezli ----
    _normalizeHandInPlace(lm, LandmarkLayout.poseEnd);
    // ---- KATMAN 2: Sag el bilek-merkezli ----
    _normalizeHandInPlace(lm, LandmarkLayout.leftEnd);

    return lm;
  }

  /// 21 noktali el bloguna (starting at handStart, 63 float) palm-normalize uygular.
  /// Bilek (nokta 0) orijini; orta parmak kokune (nokta 9) olan mesafe olcek.
  /// Bilek noktasi SIFIR kalir (Python mantigi: lh[1:] = (lh[1:] - wrist)/scale).
  static void _normalizeHandInPlace(Float32List lm, int handStart) {
    final wx = lm[handStart];
    final wy = lm[handStart + 1];
    final wz = lm[handStart + 2];
    if (_allZero3(wx, wy, wz)) return;

    final mx = lm[handStart + 9 * 3];
    final my = lm[handStart + 9 * 3 + 1];
    final mz = lm[handStart + 9 * 3 + 2];
    final dx = mx - wx, dy = my - wy, dz = mz - wz;
    final palmScale = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (palmScale <= 1e-4) return;

    final inv = 1.0 / palmScale;
    // Noktalar 1..20 (0 = bilek, olduğu gibi kalir)
    for (int p = 1; p < 21; p++) {
      final i = handStart + p * 3;
      lm[i]     = (lm[i]     - wx) * inv;
      lm[i + 1] = (lm[i + 1] - wy) * inv;
      lm[i + 2] = (lm[i + 2] - wz) * inv;
    }
  }

  /// Buffer'a normalize edilmis kare ekler. Buffer dolu ise en eskiyi atar.
  void addFrame(Float32List normalizedLm) {
    if (_buffer.length >= seqLen) _buffer.removeAt(0);
    _buffer.add(normalizedLm);
  }

  /// Minimum frame sayisi - altindaysa prediction yapilmaz.
  /// 20 frame ≈ 1000ms @20FPS — isaretin buyuk bolumu tamamlanmis olur.
  /// 10'da test ettik: padding (ilk frame'i 20x tekrar) modele egitim verisinde
  /// olmayan "uzun sabit + kisa hareket" pattern'i veriyor, model hep ayni
  /// sinifa (ornegin ARALIK %100) kilitleniyor. 20'de padding sadece 10 frame
  /// ekliyor ve sinyal daha temiz.
  static const int minFramesToPad = 20;

  /// Buffer (30 frame) hazirsa [1, 30, 1755] duz Float32List uretir.
  /// Buffer kismen doluysa (>= minFramesToPad) ilk frame tekrarlanarak padlenir —
  /// boylece "kullanici kisa isaret yapip durdurdu" senaryosunda da tahmin yapilabilir.
  ///   - velocity ekler (sadece el kisimlari)
  ///   - [-5, 5] clip
  ///
  /// Null donerse buffer cok bos (< minFramesToPad).
  Float32List? buildModelInput({bool allowPartial = false}) {
    final haveCount = _buffer.length;
    if (haveCount == 0) return null;
    if (haveCount < seqLen && !allowPartial) return null;
    if (allowPartial && haveCount < minFramesToPad) return null;

    // Pad: eksik frame'leri ilk frame ile doldur (egitim verisinde sign
    // basindan bu yana gecmis yok varsayimini tasir).
    // frame[t] -> effective index: t < pad ? 0 : t - pad
    final int padCount = haveCount >= seqLen ? 0 : seqLen - haveCount;

    // [30, 1755] flat
    final out = Float32List(seqLen * LandmarkLayout.inputSize);
    const lmPart = LandmarkLayout.rightEnd;       // 1629
    const handStart = LandmarkLayout.poseEnd;     // 1503 (pose sonu = hands basi)
    const handLen = LandmarkLayout.handVel;       // 126 (sol+sag el)

    // Gecmis kare hand bolgesi (velocity icin)
    Float32List? prevHands;

    for (int t = 0; t < seqLen; t++) {
      // padCount kadar bastan ilk frame'i tekrar et, sonrasinda gercek frame'ler
      final srcIdx = t < padCount ? 0 : t - padCount;
      final frame = _buffer[srcIdx];
      final rowOffset = t * LandmarkLayout.inputSize;

      // 1) Landmarklari kopyala (1629)
      for (int i = 0; i < lmPart; i++) {
        final v = frame[i];
        out[rowOffset + i] = v.clamp(-5.0, 5.0).toDouble();
      }

      // 2) Velocity (126): sadece hands kismi (POSE_END..RIGHT_END)
      // Python: hands = seq[:, POSE_END:]; vel[0]=0, vel[t]=hands[t]-hands[t-1]
      final velOffset = rowOffset + lmPart;
      if (prevHands == null) {
        // t=0 velocity 0
        for (int i = 0; i < handLen; i++) {
          out[velOffset + i] = 0.0;
        }
      } else {
        for (int i = 0; i < handLen; i++) {
          final d = frame[handStart + i] - prevHands[i];
          out[velOffset + i] = d.clamp(-5.0, 5.0).toDouble();
        }
      }

      // prevHands guncelle (tek bir buffer kullan, kopya gerekir)
      prevHands ??= Float32List(handLen);
      for (int i = 0; i < handLen; i++) {
        prevHands[i] = frame[handStart + i];
      }
    }

    return out;
  }

  static bool _allZero3(double a, double b, double c) {
    // Python np.allclose(lm, 0) varsayilan atol=1e-8.
    // MediaPipe eksik nokta -> tam 0 doner; sayilari tam 0 yerine 1e-10 atarsa problem olmaz.
    const eps = 1e-7;
    return a.abs() < eps && b.abs() < eps && c.abs() < eps;
  }
}

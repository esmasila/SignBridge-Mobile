import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:camera/camera.dart';
import 'package:socket_io_client/socket_io_client.dart' as sio;
import 'package:flutter_tts/flutter_tts.dart';
import '../services/api_service.dart';
import '../services/nlp_service.dart';
import '../services/frame_encoder.dart';
import '../services/landmark_processor.dart';
import '../services/local_inference.dart';
import '../services/mp_native.dart';
import 'debug_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  bool _isRunning = false;

  // ───────── Faz A: stream + Socket.IO ─────────
  sio.Socket? _socket;
  bool _socketConnected = false;
  bool _streamStarted = false;
  int _inflight = 0;
  DateTime _lastSendAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const int _targetIntervalMs = 90;   // ~11 FPS (backend + ağ buna rahat yetişir)
  static const int _maxInflight      = 2;    // backpressure

  // ───────── Faz B: telefonda GRU ─────────
  // ApiService.localInferenceMode true ise: sunucu ws_frame_lm alir, landmarks
  // doner; telefon normalize + velocity + ONNX inference yapar.
  late final bool _localMode;
  final LocalInference _localInf = LocalInference();
  final LandmarkProcessor _lmProc = LandmarkProcessor();
  bool _localReady = false;
  // onnxruntime session aynı anda tek inference — concurrent çağrı native crash yapar
  bool _inferencing = false;
  int _skippedInference = 0;
  // Pending FINAL: handsJustLeft olayi _inferencing meşgulken gelirse kelimeyi
  // kaybetmemek icin burada tutulur; aktif inference bitince fire edilir.
  Float32List? _pendingFinalInput;

  // ───────── Faz C: telefonda MediaPipe ─────────
  // _localMp true ise socket hic kullanilmaz; MP ve GRU telefonda.
  final MpNative _mp = MpNative();
  bool _localMp = false;
  bool _mpInflight = false;  // tek frame in-flight (MP sira sira calisir)
  bool _mpFirstLogged = false;
  bool _mpFirstResultLogged = false;

  // V2 backend orijinal degerleri — Phase A'da BARIŞ "default attractor"
  // gurultusu sadece bu strict esiklerle filtrelenir. Phase B/C icin
  // gevsetilmisti ama Phase A'da web gibi calisma icin orijinale donduk.
  // Model rastgele/gecici input'a 99% conf ile BARIŞ diyor (Python'da kanitlandi).
  // 4 kare ust uste ≥%82 = ~0.5sn sustained signal — gercek isaret bu sureyi
  // kolayca tutar, transient noise tutamaz.
  static const double _confThreshold  = 0.82;
  static const double _confFastTrack  = 0.94;
  static const int    _smoothNeeded   = 4;
  static const int    _smoothFast     = 2;
  static const int    _sameWordMax    = 3;
  static const int    _minWordGapMs   = 500;

  // State matching mobile.html
  String _currentPrediction = '';
  double _confidence = 0.0;
  bool _handsDetected = false;
  List<String> _sentenceWords = [];
  List<Map<String, dynamic>> _pastSentences = [];
  String _turkishSentence = '';

  // ── TTS ──
  final FlutterTts _tts = FlutterTts();
  Timer? _autoSpeakTimer;
  bool _autoSpeak = true;
  bool _ttsReady = false;

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage('tr-TR');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      _ttsReady = true;
    } catch (e) {
      DebugLog.add('TTS', 'init error: $e', isError: true);
    }
  }

  Future<void> _speakNow() async {
    if (!_ttsReady || _turkishSentence.trim().isEmpty) return;
    try {
      await _tts.stop();
      await _tts.speak(_turkishSentence);
    } catch (e) {
      DebugLog.add('TTS', 'speak error: $e', isError: true);
    }
  }

  void _scheduleAutoSpeak() {
    if (!_autoSpeak) return;
    _autoSpeakTimer?.cancel();
    _autoSpeakTimer = Timer(const Duration(milliseconds: 1800), () {
      if (_sentenceWords.isNotEmpty) _speakNow();
    });
  }
  bool _sentenceComplete = false;
  String _smoothWord = '';
  int _smoothCount = 0;
  String _lastAddedWord = '';
  int _sameWordCount = 0;
  DateTime? _lastWordTime;
  DateTime? _lastHandTime;
  int _bufferSize = 0;
  String _statusMsg = 'Hazır';
  // Inter-sign pause reset: eller 500ms kaybolunca buffer'i bir kez sifirla
  bool _pauseResetDone = false;
  int _fps = 0;
  int _frameCount = 0;
  int _fpsLogCounter = 0;
  DateTime _fpsTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    // Versiyon markori: debug ekraninda en altta gorunur, hangi APK yuklu oldugunu
    // kesin olarak soyler. Her build'de string degisir.
    DebugLog.add('BUILD', 'v24-tts-mobile (2026-05-03)');
    WidgetsBinding.instance.addObserver(this);
    _localMode = ApiService.localInferenceMode;
    _initTts();
    _initCamera();
    // NOT: Socket'i koşulsuz başlatmıyoruz.
    //   - Phase C (native MP) calisacaksa sunucuya zaten gerek yok.
    //   - Phase C basarisiz olursa Phase B/A socket'e duser.
    // Bu yuzden _initLocal()'i bekleyip, _localMp=false ise socket'i aciyoruz.
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    if (_localMode) {
      await _initLocal();
    }
    // Phase C hazir degilse (ya _localMode kapali ya da MP init patlamis) socket sart.
    if (!_localMp) {
      _initSocket();
    } else {
      DebugLog.add('WS', 'socket skipped (Phase C active)');
      if (mounted) setState(() => _statusMsg = 'Hazır (offline)');
    }
  }

  Future<void> _initLocal() async {
    try {
      await _localInf.init();
      _localReady = true;
      DebugLog.add('INF', 'Local ONNX loaded');
    } catch (e) {
      _localReady = false;
      DebugLog.add('INF', 'Local init error: $e', isError: true);
    }

    // ─── TEŞHİS MODU: Phase C'yi kapat, Phase B'yi zorla ───
    // Phase C'de MediaPipe Tasks landmarklari eğitimin mp.solutions.holistic
    // uzayiyla birebir örtüşmüyor olabilir; ayrica FPS=9 → padding artifaktlari.
    // Phase B (sunucu holistic + telefon ONNX) egitim pipeline'iyla bire bir ayni.
    // Bu build'de Phase C init'ini atliyoruz; socket acilacak, sunucu landmark
    // yollayacak, telefon sadece normalize+GRU yapacak.
    //
    // Phase C'yi tekrar acmak icin: asagidaki 2 satiri kaldir + "await _mp.init()"
    // blogunu uncomment et.
    _localMp = false;
    DebugLog.add('MP', 'Phase C disabled — forcing Phase B (server landmarks)');
    // try {
    //   await _mp.init();
    //   _localMp = _mp.ready;
    //   DebugLog.add('MP', _localMp ? 'Native MediaPipe ready' : 'Native MP init returned false');
    // } catch (e) {
    //   _localMp = false;
    //   DebugLog.add('MP', 'Native MP init error: $e', isError: true);
    // }
  }

  bool _wasRunningBeforePause = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _wasRunningBeforePause = _isRunning;
      if (_isRunning) _stopCapture();
    } else if (state == AppLifecycleState.resumed) {
      if (_wasRunningBeforePause) _startCapture();
    }
  }

  // ────────────── Socket.IO bağlantısı ──────────────
  void _initSocket() {
    try {
      final url = ApiService.mainBaseUrl;  // http://<ip>:5050
      _socket = sio.io(
        url,
        sio.OptionBuilder()
          .setTransports(['websocket'])       // polling yok, direkt ws
          .disableAutoConnect()
          .setReconnectionAttempts(9999)
          .setReconnectionDelay(500)
          .setTimeout(5000)
          .build(),
      );

      _socket!.onConnect((_) {
        _socketConnected = true;
        DebugLog.add('WS', 'connected: $url  localMode=$_localMode');
        if (mounted) setState(() => _statusMsg = 'Bağlandı');
      });
      _socket!.onDisconnect((_) {
        _socketConnected = false;
        DebugLog.add('WS', 'disconnected');
      });
      _socket!.onConnectError((e) {
        DebugLog.add('WS', 'connect error: $e', isError: true);
      });
      // Faz A: tum isi sunucu yapiyor -> ws_pred
      // Faz B: sunucu landmarklari yolluyor, GRU telefonda -> ws_lm
      if (_localMode) {
        _socket!.on('ws_lm', _onLandmarks);
      } else {
        _socket!.on('ws_pred', _onPrediction);
      }

      _socket!.connect();
    } catch (e) {
      DebugLog.add('WS', 'init error: $e', isError: true);
    }
  }

  // Faz B: sunucudan sadece landmark (1629 float32) geldiginde calisir.
  void _onLandmarks(dynamic data) {
    if (_inflight > 0) _inflight--;
    if (!mounted || data is! Map) return;
    if (data['success'] != true) return;
    if (!_localReady) {
      // Model henuz yuklenmedi; UI'yi bilgilendir
      if (_statusMsg != 'Model yükleniyor...') {
        setState(() => _statusMsg = 'Model yükleniyor...');
      }
      return;
    }

    final handsDetected = (data['hand'] ?? false) as bool;
    final lmRaw = data['lm'];

    // lm: flask-socketio binary -> Dart tarafinda Uint8List / List<int>
    Uint8List? bytes;
    if (lmRaw is Uint8List) {
      bytes = lmRaw;
    } else if (lmRaw is List) {
      bytes = Uint8List.fromList(List<int>.from(lmRaw));
    } else if (lmRaw is String) {
      // base64 fallback (kullanilmiyor ama guvenlik)
      // import 'dart:convert' gerekmiyor; basit atlama
    }
    if (bytes == null || bytes.length != LandmarkLayout.rightEnd * 4) {
      DebugLog.add('LM', 'Bad landmark payload: ${bytes?.length ?? 0}', isError: true);
      return;
    }

    // Transition tespit
    final wasHandsDetected = _handsDetected;
    final handsJustLeft = wasHandsDetected && !handsDetected;

    // Inter-sign pause: eller 500ms+ kayipsa buffer'i bir kez sifirla.
    if (handsDetected) {
      _pauseResetDone = false;
    } else if (!_pauseResetDone &&
        _lastHandTime != null &&
        DateTime.now().difference(_lastHandTime!).inMilliseconds > 500 &&
        _lmProc.bufferSize > 0) {
      _lmProc.reset();
      _smoothWord = '';
      _smoothCount = 0;
      _pauseResetDone = true;
      setState(() {
        _bufferSize = 0;
        _currentPrediction = '';
        _confidence = 0.0;
      });
      DebugLog.add('LM', 'buffer reset (inter-sign pause)');
    }

    // 4 byte/lik float32 -> Float32List
    final lm = Float32List.view(bytes.buffer, bytes.offsetInBytes, LandmarkLayout.rightEnd);
    // Sunucudaki extract_landmarks zaten float32 veriyor (np.float32.tobytes).
    // Ancak view'i mutate edeceğiz, kopyalayalım:
    final lmCopy = Float32List.fromList(lm);
    LandmarkProcessor.normalizeLandmarks(lmCopy);
    if (handsDetected) {
      _lmProc.addFrame(lmCopy);
    }

    // UI guncelle
    setState(() {
      _handsDetected = handsDetected;
      _bufferSize = _lmProc.bufferSize;
    });
    if (handsDetected) {
      _lastHandTime = DateTime.now();
      _sentenceComplete = false;
      final filling = _lmProc.bufferSize < LandmarkProcessor.seqLen;
      final nextMsg = filling
          ? 'Buffer: ${_lmProc.bufferSize}/${LandmarkProcessor.seqLen}'
          : 'El algılandı';
      if (_statusMsg != nextMsg) setState(() => _statusMsg = nextMsg);
    } else {
      if (_statusMsg != 'Bekleniyor...') setState(() => _statusMsg = 'Bekleniyor...');
    }

    // Prediction trigger (Phase C ile ayni mantik — pending FINAL dahil)
    final bufferFull = _lmProc.ready;
    final canRollingPredict = _lmProc.bufferSize >= LandmarkProcessor.minFramesToPad;
    final canFinalPredict = handsJustLeft && canRollingPredict;

    if (!bufferFull && !canRollingPredict && !canFinalPredict) {
      _maybeCompleteSentence(handsDetected);
      return;
    }

    if (canFinalPredict) {
      final snap = _lmProc.buildModelInput(allowPartial: !bufferFull);
      if (snap != null) {
        _pendingFinalInput = snap;
        DebugLog.add('LM', 'FINAL queued: buf=${_lmProc.bufferSize}/30 '
            '(inferencing=$_inferencing)');
      }
      _lmProc.reset();
      setState(() => _bufferSize = 0);
    }

    if (_inferencing) {
      _skippedInference++;
      _maybeCompleteSentence(handsDetected);
      return;
    }

    if (_pendingFinalInput != null) {
      _runPendingFinalIfAny();
      _maybeCompleteSentence(handsDetected);
      return;
    }

    final modelInput = _lmProc.buildModelInput(allowPartial: !bufferFull);
    if (modelInput == null) {
      _maybeCompleteSentence(handsDetected);
      return;
    }

    final isPartial = !bufferFull;
    _inferencing = true;
    final capturedHands = handsDetected;

    if (isPartial) {
      DebugLog.add('LM',
          'partial predict: buf=${_lmProc.bufferSize}/30 [rolling]');
    }

    _localInf.predict(modelInput).then((result) {
      _inferencing = false;
      if (!mounted || result == null) {
        _runPendingFinalIfAny();
        return;
      }
      if (result.confidence > _confThreshold) {
        DebugLog.add('TOPK',
            '${result.topKString} (buf=${_lmProc.bufferSize}/30)');
      }
      _applyPrediction(result.label, result.confidence, capturedHands,
          immediate: false, bufferFull: bufferFull);
      _runPendingFinalIfAny();
    }).catchError((e, st) {
      _inferencing = false;
      DebugLog.add('INF', 'predict error: $e', isError: true);
      _runPendingFinalIfAny();
    });

    _maybeCompleteSentence(handsDetected);
  }

  // Fast-track yumusatma logic'i — her iki yoldan da ayni (Faz A ve B).
  int _predLogCount = 0;
  void _applyPrediction(String predText, double conf, bool handsDetected,
      {bool immediate = false, bool bufferFull = true}) {
    setState(() {
      // El yokken canli tahmini gosterme (gurultuyu filtrele)
      _currentPrediction = handsDetected ? predText : '';
      _confidence = handsDetected ? conf : 0.0;
    });

    // Debug: her 5 tahminden 1'ini logla (conf dagilimini gorebilmek icin)
    _predLogCount++;
    if (_predLogCount % 5 == 0 || immediate) {
      DebugLog.add('PRED',
          '$predText conf=${(conf*100).toStringAsFixed(1)}% hands=$handsDetected '
          'buf=${_lmProc.bufferSize}/${LandmarkProcessor.seqLen}${immediate ? " [FINAL]" : ""}');
    }

    // Kelime ekleme kosullari:
    //   - immediate=true (FINAL): eller indi, isaret bitti — direkt commit.
    //   - bufferFull=true: 30 frame tamamlandi — normal smoothing + fast-track.
    //   - bufferFull=false && !immediate: rolling partial (buf 10-29, eller hala
    //     havada) — sadece UI guncelle, commit ETME. Aksi halde isareti yaparken
    //     yari yolda yanlis kelime eklenir (kullanici ANNE yaparken buf=10'da
    //     model ANNE tahmin etti, kelime eklendi, sonra isaret devam etti, buf=10
    //     tekrar doldu, model bu kez BARIS tahmin etti, o da eklendi = tek
    //     isaretten 2 yanlis kelime).
    if (!handsDetected) {
      _smoothWord = '';
      _smoothCount = 0;
      return;
    }
    if (predText.isEmpty || conf <= _confThreshold) return;

    if (immediate) {
      _addWord(predText);
      _smoothWord = '';
      _smoothCount = 0;
    } else if (bufferFull) {
      // Full-buffer rolling: smoothing + fast-track
      if (predText == _smoothWord) {
        _smoothCount++;
      } else {
        _smoothWord = predText;
        _smoothCount = 1;
      }
      final needed = (conf >= _confFastTrack) ? _smoothFast : _smoothNeeded;
      if (_smoothCount >= needed) {
        _addWord(predText);
        _smoothCount = 0;
      }
    }
    // else: rolling partial — UI guncellendi ama commit yok, smoothing sayaci
    // degismiyor (cunku partial tahminleri karisik/isabetsiz — full buffer'i bekle).

    if (_sentenceComplete && handsDetected && predText.isNotEmpty && conf > _confThreshold) {
      _archiveSentence();
    }
  }

  void _onPrediction(dynamic data) {
    if (_inflight > 0) _inflight--;
    if (!mounted) return;
    if (data is! Map) return;

    if (data['success'] != true) return;
    final predText = (data['prediction_text'] ?? '').toString();
    final conf = (data['confidence'] ?? 0.0 as num).toDouble();
    final handsDetected = data['hands_detected'] ?? false;
    final bufSize = data['buffer_size'] ?? 0;
    final msg = data['message'] ?? '';

    setState(() {
      _currentPrediction = predText;
      _confidence = conf;
      _handsDetected = handsDetected;
      _bufferSize = bufSize is int ? bufSize : 0;
    });

    // Inter-sign pause: eller 500ms+ kayipsa SUNUCU buffer'ini bir kez sifirla.
    // Aksi halde sunucu deque'i onceki isaretin frame'leriyle dolu kalir
    // (3-4sn @ 8 FPS), sonraki isarete karisip BARIŞ'a dustugu durum.
    if (handsDetected) {
      _pauseResetDone = false;
    } else if (!_pauseResetDone &&
        _lastHandTime != null &&
        DateTime.now().difference(_lastHandTime!).inMilliseconds > 500 &&
        _socket != null && _socketConnected) {
      _socket!.emit('ws_reset');
      _smoothWord = '';
      _smoothCount = 0;
      _pauseResetDone = true;
      DebugLog.add('WS', 'ws_reset (inter-sign pause)');
    }

    if (handsDetected) {
      _lastHandTime = DateTime.now();
      _sentenceComplete = false;
      if (_statusMsg != 'El algılandı') setState(() => _statusMsg = 'El algılandı');
    } else {
      final next = msg.toString().isNotEmpty ? msg.toString() : 'Bekleniyor...';
      if (_statusMsg != next) setState(() => _statusMsg = next);
    }

    // V2: Fast-track yumusatma
    if (handsDetected && predText.isNotEmpty && conf > _confThreshold) {
      if (predText == _smoothWord) {
        _smoothCount++;
      } else {
        _smoothWord = predText;
        _smoothCount = 1;
      }
      final needed = (conf >= _confFastTrack) ? _smoothFast : _smoothNeeded;
      if (_smoothCount >= needed) {
        _addWord(predText);
        _smoothCount = 0;
      }
    } else if (!handsDetected) {
      _smoothWord = '';
      _smoothCount = 0;
    }

    // Sentence completion: 2 seconds without hands
    if (_sentenceWords.isNotEmpty && !_sentenceComplete && !handsDetected &&
        _lastHandTime != null &&
        DateTime.now().difference(_lastHandTime!).inMilliseconds > 2000) {
      _completeSentence();
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted && _sentenceComplete) _archiveSentence();
      });
    }

    // If sentence complete and new confident prediction with hands, archive first
    if (_sentenceComplete && handsDetected && predText.isNotEmpty && conf > _confThreshold) {
      _archiveSentence();
    }
  }

  // ────────────── Kamera ──────────────
  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
    } catch (e) {
      DebugLog.add('CAM', 'Camera init error: $e', isError: true);
      return;
    }
    if (_cameras.isEmpty) return;
    _cameraIndex = _cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.front);
    if (_cameraIndex < 0) _cameraIndex = 0;
    await _setupCamera(_cameras[_cameraIndex]);
  }

  Future<void> _setupCamera(CameraDescription camera) async {
    final old = _controller;
    if (old != null) {
      _controller = null;
      try {
        if (_streamStarted) await old.stopImageStream();
      } catch (_) {}
      try { await old.dispose(); } catch (_) {}
      _streamStarted = false;
    }

    // YUV420 streaming (Android) / BGRA8888 fallback (iOS).
    // ResolutionPreset.medium ≈ 640x480 — FPS kritiği: 720p'de MP Tasks ~12 FPS,
    // 30-frame buffer 2.5sn sürüyor → dogal konusma hizi (0.5-0.8sn/isaret) icin
    // cok yavas. 480p'de MP ~20+ FPS → 30 frame 1.5sn, cok daha akici.
    // Landmark doğruluğu hafif düşer ama FPS x hız kazanimi buna bariz üstün.
    final ctrl = CameraController(
      camera, ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await ctrl.initialize();
      _controller = ctrl;
      if (mounted) setState(() {});
      DebugLog.add('CAM',
          'Camera ready: ${ctrl.value.previewSize}  sensor=${camera.sensorOrientation}°  lens=${camera.lensDirection}');
    } catch (e) {
      DebugLog.add('CAM', 'Camera setup error: $e', isError: true);
    }
  }

  void _flipCamera() async {
    if (_cameras.length < 2) return;
    final wasRunning = _isRunning;
    try {
      // 1) Stream'i durdur
      if (_streamStarted) {
        try { await _controller?.stopImageStream(); } catch (_) {}
        _streamStarted = false;
      }
      _inflight = 0;
      _mpInflight = false;

      // 2) ONCE controller'i null'a cek ve UI'da loading goster
      // (Bu sayede CameraPreview disposed bir controller'i render etmeye calismaz)
      final old = _controller;
      _controller = null;
      if (mounted) setState(() {
        _isRunning = false;
        _statusMsg = 'Kamera değiştiriliyor...';
      });
      // Bir frame bekle ki UI null'i gorup loading'e gecsin
      await Future.delayed(const Duration(milliseconds: 50));

      // 3) Eski controller'i guvenli dispose
      try { await old?.dispose(); } catch (_) {}

      // 4) Yeni cama gec
      _cameraIndex = (_cameraIndex + 1) % _cameras.length;
      await _setupCamera(_cameras[_cameraIndex]);
      if (wasRunning) _startCapture();
    } catch (e) {
      DebugLog.add('CAM', 'flip error: $e', isError: true);
      if (mounted) setState(() { _statusMsg = 'Kamera değişim hatası'; });
    }
  }

  // ────────────── Start/Stop streaming ──────────────
  void _startCapture() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_streamStarted) return;
    setState(() { _isRunning = true; _statusMsg = 'Başlatılıyor...'; });
    _inflight = 0;
    _lastSendAt = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await _controller!.startImageStream(_onCameraFrame);
      _streamStarted = true;
      DebugLog.add('CAM', 'image stream started');
    } catch (e) {
      DebugLog.add('CAM', 'startImageStream error: $e', isError: true);
      if (mounted) setState(() { _isRunning = false; _statusMsg = 'Hata'; });
    }
  }

  void _stopCapture() async {
    if (_streamStarted) {
      try { await _controller?.stopImageStream(); } catch (_) {}
      _streamStarted = false;
    }
    _inflight = 0;
    if (mounted) setState(() { _isRunning = false; _statusMsg = 'Durduruldu'; });
  }

  // ────────────── Frame callback (30 FPS) ──────────────
  void _onCameraFrame(CameraImage image) {
    if (!_isRunning) return;

    final now = DateTime.now();

    // FPS counter + efektif buffer-fill rate
    _frameCount++;
    if (now.difference(_fpsTime).inMilliseconds >= 1000) {
      if (mounted) setState(() => _fps = _frameCount);
      // Her 3 sn bir FPS logla ki gerçekten kac frame geldigini gorelim.
      if (_fpsLogCounter++ % 3 == 0) {
        DebugLog.add('FPS',
            'cam=$_frameCount/sn  bufferedFrames=${_lmProc.bufferSize}/30  '
            'skipped_inf=$_skippedInference');
      }
      _frameCount = 0;
      _fpsTime = now;
    }

    // Faz C: tum is telefonda — native MP calistir, sonucu direkt islestir.
    if (_localMp && _localReady) {
      if (_mpInflight) return;  // backpressure (MP sira sira)
      _mpInflight = true;

      final rotation = _cameras[_cameraIndex].sensorOrientation;
      // Egitim verisi hep aynali (on cam) — arka cam'i de mirror'la ki
      // model ayni el dagilimini gorsun, yoksa sag-sol karisir
      final mirror = true;

      if (!_mpFirstLogged) {
        _mpFirstLogged = true;
        DebugLog.add('MP', 'first frame: ${image.width}x${image.height} '
            'planes=${image.planes.length} rot=$rotation mirror=$mirror '
            'yBytes=${image.planes[0].bytes.length} '
            'uStride=${image.planes[1].bytesPerRow} '
            'uPxStride=${image.planes[1].bytesPerPixel}');
      }

      _mp.processCameraImage(image, rotation: rotation, mirror: mirror).then((r) {
        _mpInflight = false;
        if (!mounted || r == null) return;
        if (!_mpFirstResultLogged) {
          _mpFirstResultLogged = true;
          DebugLog.add('MP', 'first result ok: handSeen=${r.handSeen} '
              'lm[1404..1407]=${r.landmarks[1404].toStringAsFixed(3)},'
              '${r.landmarks[1405].toStringAsFixed(3)},'
              '${r.landmarks[1406].toStringAsFixed(3)}');
        }
        _onNativeLandmarks(r.landmarks, r.handSeen);
      }).catchError((e, st) {
        _mpInflight = false;
        DebugLog.add('MP', 'process error: $e', isError: true);
      });
      return;
    }

    // Faz A/B: socket yolu
    if (!_socketConnected) return;
    if (now.difference(_lastSendAt).inMilliseconds < _targetIntervalMs) return;
    if (_inflight >= _maxInflight) return;   // backpressure

    _lastSendAt = now;

    // YUV planes'i kopyala (CameraImage buffer'i kisa surede geri alinir)
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final input = FrameInput(
      width: image.width,
      height: image.height,
      yRowStride: yPlane.bytesPerRow,
      uRowStride: uPlane.bytesPerRow,
      uvPixelStride: uPlane.bytesPerPixel ?? 1,
      yBytes: Uint8List.fromList(yPlane.bytes),
      uBytes: Uint8List.fromList(uPlane.bytes),
      vBytes: Uint8List.fromList(vPlane.bytes),
      rotation: _cameras[_cameraIndex].sensorOrientation,
      mirror: true,  // Her iki kamerada da mirror (egitim verisi aynali ondan)
      jpegQuality: 55,
    );

    _inflight++;
    compute(encodeYuv420ToJpeg, input).then((jpeg) {
      if (!_isRunning || _socket == null) {
        if (_inflight > 0) _inflight--;
        return;
      }
      // Faz B: landmark-only (telefon GRU yapar) veya Faz A (tamami sunucu)
      _socket!.emit(_localMode ? 'ws_frame_lm' : 'ws_frame', jpeg);
      // Yanit gelmezse inflight sayacini 2.5sn sonra serbest birak (guvenlik)
      Future.delayed(const Duration(milliseconds: 2500), () {
        if (_inflight > 0) _inflight--;
      });
    }).catchError((e) {
      if (_inflight > 0) _inflight--;
      DebugLog.add('ENC', 'encode error: $e', isError: true);
    });
  }

  // Faz C: native MP'den gelen landmark vektoru. Faz B'deki _onLandmarks ile
  // ayni mantik (normalize + buffer + inference + sentence completion).
  void _onNativeLandmarks(Float32List lm, bool handsDetected) {
    if (!_localReady) return;

    // Transition tespit: eller bu frame'de kayboldu mu? (true -> false)
    final wasHandsDetected = _handsDetected;
    final handsJustLeft = wasHandsDetected && !handsDetected;

    // Inter-sign pause: eller 500ms+ kayipsa buffer'i bir kez sifirla.
    if (handsDetected) {
      _pauseResetDone = false;
    } else if (!_pauseResetDone &&
        _lastHandTime != null &&
        DateTime.now().difference(_lastHandTime!).inMilliseconds > 500 &&
        _lmProc.bufferSize > 0) {
      _lmProc.reset();
      _smoothWord = '';
      _smoothCount = 0;
      _pauseResetDone = true;
      setState(() {
        _bufferSize = 0;
        _currentPrediction = '';
        _confidence = 0.0;
      });
      DebugLog.add('LM', 'buffer reset (inter-sign pause)');
    }

    LandmarkProcessor.normalizeLandmarks(lm);
    // Buffer SADECE eller gorunurken doluyor — 30 frame SAF isaret hareketi olsun
    // (egitim verisiyle uyumlu).
    if (handsDetected) {
      _lmProc.addFrame(lm);
    }

    setState(() {
      _handsDetected = handsDetected;
      _bufferSize = _lmProc.bufferSize;
    });
    if (handsDetected) {
      _lastHandTime = DateTime.now();
      _sentenceComplete = false;
      final filling = _lmProc.bufferSize < LandmarkProcessor.seqLen;
      final nextMsg = filling
          ? 'Buffer: ${_lmProc.bufferSize}/${LandmarkProcessor.seqLen}'
          : 'İşaret yap';
      if (_statusMsg != nextMsg) setState(() => _statusMsg = nextMsg);
    } else {
      if (_statusMsg != 'Ellerinizi gösterin') setState(() => _statusMsg = 'Ellerinizi gösterin');
    }

    // Prediction trigger — 3 kademe:
    //   (A) buf >= 30 (bufferFull): normal rolling predict
    //   (B) buf >= 20 && !bufferFull: ROLLING PARTIAL (UI only)
    //   (C) handsJustLeft && buf >= 20: FINAL [immediate] — sign bitti, commit et.
    final bufferFull = _lmProc.ready;
    final canRollingPredict = _lmProc.bufferSize >= LandmarkProcessor.minFramesToPad;
    final canFinalPredict = handsJustLeft && canRollingPredict;

    if (!bufferFull && !canRollingPredict && !canFinalPredict) {
      _maybeCompleteSentence(handsDetected);
      return;
    }

    // FINAL olayi: _inferencing mesgulse kelime kaybolmasin diye snapshot al,
    // aktif inference bitince _runPendingFinalIfAny() ile fire et.
    if (canFinalPredict) {
      final snap = _lmProc.buildModelInput(allowPartial: !bufferFull);
      if (snap != null) {
        _pendingFinalInput = snap;
        DebugLog.add('LM', 'FINAL queued: buf=${_lmProc.bufferSize}/30 '
            '(inferencing=$_inferencing)');
      }
      // Buffer'i HEMEN temizle ki bir sonraki isaret taze baslasin; snapshot
      // zaten cekildi, referans guvende.
      _lmProc.reset();
      setState(() => _bufferSize = 0);
    }

    if (_inferencing) {
      _skippedInference++;
      // FINAL meşgulken zaten queue'a alindi — aktif inference `then`'in sonunda
      // _runPendingFinalIfAny() cagirilacak.
      _maybeCompleteSentence(handsDetected);
      return;
    }

    // FINAL varsa once onu isle (queue consume)
    if (_pendingFinalInput != null) {
      _runPendingFinalIfAny();
      _maybeCompleteSentence(handsDetected);
      return;
    }

    final modelInput = _lmProc.buildModelInput(allowPartial: !bufferFull);
    if (modelInput == null) {
      _maybeCompleteSentence(handsDetected);
      return;
    }

    final isPartial = !bufferFull;           // padding needed
    // FINAL artik pending queue path'inden gidiyor — bu kodda sadece rolling.
    _inferencing = true;
    final capturedHands = handsDetected;

    if (isPartial) {
      DebugLog.add('LM',
          'partial predict: buf=${_lmProc.bufferSize}/30 [rolling]');
    }

    _localInf.predict(modelInput).then((result) {
      _inferencing = false;
      if (!mounted || result == null) {
        _runPendingFinalIfAny();
        return;
      }
      if (result.confidence > _confThreshold) {
        DebugLog.add('TOPK',
            '${result.topKString} (buf=${_lmProc.bufferSize}/30)');
      }
      _applyPrediction(result.label, result.confidence, capturedHands,
          immediate: false, bufferFull: bufferFull);
      // Rolling partial'da buffer birikmeye devam etsin (commit yok).
      // Aktif inference bitti; queued FINAL varsa simdi fire et.
      _runPendingFinalIfAny();
    }).catchError((e) {
      _inferencing = false;
      DebugLog.add('INF', 'predict error: $e', isError: true);
      _runPendingFinalIfAny();
    });

    _maybeCompleteSentence(handsDetected);
  }

  /// Pending FINAL inputu varsa ve inference bos ise fire et. Aksi halde
  /// no-op. (Snapshot zaten tarihte alindi; _lmProc.bufferSize'a bakmaz.)
  void _runPendingFinalIfAny() {
    final input = _pendingFinalInput;
    if (input == null || _inferencing) return;
    _pendingFinalInput = null;
    _inferencing = true;
    DebugLog.add('LM', 'FINAL firing (from queue)');
    _localInf.predict(input).then((result) {
      _inferencing = false;
      if (!mounted || result == null) return;
      DebugLog.add('TOPK', '[FINAL] ${result.topKString}');
      _applyPrediction(result.label, result.confidence, true,
          immediate: true, bufferFull: false);
      // Yeni pending olmus olabilir (nadir) — recursive deneyelim.
      _runPendingFinalIfAny();
    }).catchError((e) {
      _inferencing = false;
      DebugLog.add('INF', 'FINAL predict error: $e', isError: true);
    });
  }

  void _maybeCompleteSentence(bool handsDetected) {
    if (_sentenceWords.isNotEmpty && !_sentenceComplete && !handsDetected &&
        _lastHandTime != null &&
        DateTime.now().difference(_lastHandTime!).inMilliseconds > 2000) {
      _completeSentence();
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted && _sentenceComplete) _archiveSentence();
      });
    }
  }

  // ────────────── addWord / sentence logic (degismedi) ──────────────
  void _addWord(String word) {
    if (_sentenceComplete) _archiveSentence();

    final now = DateTime.now();
    if (word != _lastAddedWord && _lastWordTime != null &&
        now.difference(_lastWordTime!).inMilliseconds < _minWordGapMs) return;

    if (word == _lastAddedWord) {
      _sameWordCount++;
      if (_sameWordCount > _sameWordMax) return;
    } else {
      _sameWordCount = 0;
    }
    _lastAddedWord = word;
    _lastWordTime = now;

    if (_sentenceWords.isNotEmpty && _sentenceWords.last == word) return;
    if (_sentenceWords.where((w) => w == word).length >= 2) return;

    setState(() {
      _sentenceWords.add(word);
      _turkishSentence = NlpService.glossToTurkish(_sentenceWords);
    });

    // 1.8 sn yeni kelime gelmezse otomatik sesli oku
    _scheduleAutoSpeak();

    DebugLog.add('CAM', 'Added word: $word → $_turkishSentence');

    // KRITIK: Kelime eklendikten sonra TUM buffer'lari sifirla.
    //   - _lmProc: lokal buffer (Phase B/C)
    //   - SUNUCU buffer: Phase A'da deque(maxlen=30) sunucuda donuyor.
    //     Sifirlanmazsa onceki isaretin frame'leri 3-4sn boyunca buffer'da
    //     kalir, sonraki isarete karisir, model BARIŞ default'una duser.
    //     ESKI BUG: _lmProc.reset() yapiliyordu ama ws_reset emit edilmiyordu;
    //     Phase A'da _lmProc bos zaten, gercek buffer sunucuda.
    _lmProc.reset();
    if (_socket != null && _socketConnected) {
      _socket!.emit('ws_reset');
      DebugLog.add('WS', 'ws_reset (after word)');
    }
    _smoothWord = '';
    _smoothCount = 0;
    setState(() {
      _bufferSize = 0;
      // UI: "hala merhaba yaziyor" sorununu cozmek icin ekrandaki canli
      // tahmini temizle. Yeni isaret icin buffer dolunca yenisi yazilacak.
      _currentPrediction = '';
      _confidence = 0.0;
    });
    DebugLog.add('LM', 'buffer reset after word: $word');
  }

  void _completeSentence() {
    setState(() {
      _sentenceComplete = true;
      _turkishSentence = NlpService.glossToTurkish(_sentenceWords);
    });
    DebugLog.add('CAM', 'Sentence complete: $_turkishSentence');
  }

  void _archiveSentence() {
    if (_sentenceWords.isNotEmpty) {
      setState(() {
        _pastSentences.insert(0, {
          'words': List<String>.from(_sentenceWords),
          'turkish': _turkishSentence,
          'time': DateTime.now(),
        });
        if (_pastSentences.length > 20) _pastSentences.removeLast();
      });
    }
    _sentenceWords.clear();
    _turkishSentence = '';
    _lastAddedWord = '';
    _sameWordCount = 0;
    _sentenceComplete = false;
  }

  void _clearSentence() {
    setState(() {
      _sentenceWords.clear();
      _turkishSentence = '';
      _lastAddedWord = '';
      _sentenceComplete = false;
      _smoothCount = 0;
      _smoothWord = '';
      _sameWordCount = 0;
      _lastWordTime = null;
      _bufferSize = 0;
    });
    // Yerel buffer'i (Faz B) sifirla
    _lmProc.reset();
    // Sunucu buffer'ini da sifirla (Faz A icin, ws_reset ws_sess.buffer atar)
    if (_socket != null && _socketConnected) {
      _socket!.emit('ws_reset');
    } else {
      ApiService.resetBuffer();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoSpeakTimer?.cancel();
    try { _tts.stop(); } catch (_) {}
    if (_streamStarted) {
      try { _controller?.stopImageStream(); } catch (_) {}
      _streamStarted = false;
    }
    _controller?.dispose();
    try {
      _socket?.dispose();
    } catch (_) {}
    if (_localMode) {
      try { _localInf.dispose(); } catch (_) {}
    }
    // NOT: _mp.close() cagirmiyoruz — screen disposes oldugunda executor'u
    // kapatirsak re-entry'de RejectedExecutionException aliyorduk. Runner
    // Activity yasami boyunca ayakta kalir; MainActivity.onDestroy'da temizlenir.
    super.dispose();
  }

  // ────────────── UI (degismedi) ──────────────
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(20),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                children: [
                  Builder(builder: (ctx) {
                    final c = _controller;
                    // Sik kontrol: dispose edilmis ya da hata almis controller'a dokunma
                    if (c == null ||
                        !c.value.isInitialized ||
                        c.value.hasError ||
                        c.value.previewSize == null) {
                      return const Center(child: CircularProgressIndicator(color: Colors.white54));
                    }
                    final ps = c.value.previewSize!;
                    return Positioned.fill(
                      child: FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: ps.height,
                          height: ps.width,
                          child: CameraPreview(c),
                        ),
                      ),
                    );
                  }),

                  if (_isRunning)
                    Positioned(
                      top: 10, left: 10, right: 10,
                      child: Row(
                        children: [
                          _statusChip(
                            _handsDetected ? 'El algılandı' : _statusMsg,
                            _handsDetected ? const Color(0xFF22C55E) : Colors.black54,
                          ),
                          const Spacer(),
                          if (_localMp)
                            _statusChip('DEVICE', const Color(0xFF10B981))
                          else if (_localMode)
                            _statusChip(_localReady ? 'LOCAL' : 'LOCAL…',
                                _localReady ? const Color(0xFF10B981) : Colors.orange),
                          const SizedBox(width: 4),
                          _statusChip('${_fps}fps', Colors.black54),
                          if (!_localMp) ...[
                            const SizedBox(width: 4),
                            _statusChip(_socketConnected ? 'WS✓' : 'WS✗',
                                _socketConnected ? const Color(0xFF5B4CDB) : Colors.red),
                          ],
                        ],
                      ),
                    ),

                  if (_isRunning && _handsDetected && _currentPrediction.isNotEmpty && _confidence > _confThreshold)
                    Positioned(
                      top: 44, left: 0, right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF5B4CDB),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [BoxShadow(color: const Color(0xFF5B4CDB).withValues(alpha: 0.3), blurRadius: 10)],
                          ),
                          child: Text(
                            '${NlpService.glossToTR[_currentPrediction] ?? _currentPrediction}  %${(_confidence * 100).toInt()}',
                            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),

                  if (_isRunning && _bufferSize > 0 && _bufferSize < 30)
                    Positioned(
                      bottom: 50, left: 12, right: 12,
                      child: Column(
                        children: [
                          Text('Buffer: $_bufferSize/30', style: const TextStyle(color: Colors.white54, fontSize: 10)),
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: _bufferSize / 30.0,
                              minHeight: 3,
                              backgroundColor: Colors.white12,
                              valueColor: const AlwaysStoppedAnimation(Color(0xFF5B4CDB)),
                            ),
                          ),
                        ],
                      ),
                    ),

                  Positioned(
                    bottom: 10, left: 10, right: 10,
                    child: Row(
                      children: [
                        if (_isRunning)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.fiber_manual_record, color: Colors.white, size: 8),
                                SizedBox(width: 4),
                                Text('CANLI', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                              ],
                            ),
                          ),
                        const Spacer(),
                        if (_cameras.length >= 2)
                          GestureDetector(
                            onTap: _flipCamera,
                            child: Container(
                              width: 36, height: 36,
                              decoration: const BoxDecoration(color: Colors.black38, shape: BoxShape.circle),
                              child: const Icon(Icons.flip_camera_android, color: Colors.white, size: 18),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _sentenceComplete ? Icons.check_circle : Icons.translate,
                    size: 14,
                    color: _sentenceComplete ? const Color(0xFF10B981) : const Color(0xFF5B4CDB),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _sentenceComplete ? 'Tamamlandı' : 'Tanınan Kelimeler',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey[500]),
                  ),
                  const Spacer(),
                  if (_sentenceWords.isNotEmpty)
                    GestureDetector(
                      onTap: _clearSentence,
                      child: Icon(Icons.close_rounded, size: 18, color: Colors.grey[400]),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (_sentenceWords.isNotEmpty)
                Wrap(
                  spacing: 6, runSpacing: 6,
                  children: _sentenceWords.asMap().entries.map((e) {
                    final isLast = e.key == _sentenceWords.length - 1;
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: isLast ? const Color(0xFF5B4CDB) : const Color(0xFF5B4CDB).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        NlpService.glossToTR[e.value] ?? e.value,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                            color: isLast ? Colors.white : const Color(0xFF5B4CDB)),
                      ),
                    );
                  }).toList(),
                ),
              if (_sentenceWords.isNotEmpty) const SizedBox(height: 8),
              Text(
                _turkishSentence.isEmpty
                    ? 'İşaret yapın...'
                    : _sentenceComplete ? _turkishSentence : '$_turkishSentence...',
                style: TextStyle(
                  fontSize: 14,
                  color: _turkishSentence.isEmpty ? Colors.grey[400] : const Color(0xFF1A1A2E),
                  fontWeight: _turkishSentence.isEmpty ? FontWeight.w400 : FontWeight.w500,
                  fontStyle: _turkishSentence.isEmpty ? FontStyle.italic : FontStyle.normal,
                ),
              ),
            ],
          ),
        ),

        if (_pastSentences.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            constraints: const BoxConstraints(maxHeight: 70),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _pastSentences.length > 3 ? 3 : _pastSentences.length,
              itemBuilder: (_, i) {
                final s = _pastSentences[i];
                return Container(
                  margin: const EdgeInsets.only(bottom: 3),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF5B4CDB).withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(8),
                    border: Border(left: BorderSide(color: const Color(0xFF5B4CDB).withValues(alpha: 0.4), width: 3)),
                  ),
                  child: Row(
                    children: [
                      Expanded(child: Text(s['turkish'] ?? '', style: TextStyle(fontSize: 11, color: Colors.grey[600]))),
                      Text((s['time'] as DateTime).toString().substring(11, 19),
                          style: TextStyle(fontSize: 9, color: Colors.grey[400])),
                    ],
                  ),
                );
              },
            ),
          ),

        Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, MediaQuery.of(context).padding.bottom + 8),
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: () { if (_isRunning) _stopCapture(); else _startCapture(); },
              icon: Icon(_isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 22),
              label: Text(_isRunning ? 'Durdur' : 'Başla',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isRunning ? const Color(0xFFEF4444) : const Color(0xFF5B4CDB),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _statusChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }
}

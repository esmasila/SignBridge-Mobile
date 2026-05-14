import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../services/api_service.dart';
import '../services/nlp_service.dart';
import '../services/local_server.dart';
import 'debug_screen.dart';

class AvatarScreen extends StatefulWidget {
  const AvatarScreen({super.key});

  @override
  State<AvatarScreen> createState() => _AvatarScreenState();
}

class _AvatarScreenState extends State<AvatarScreen> {
  WebViewController? _webController;
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  List<String> _knownWords = [];
  bool _isPlaying = false;
  bool _isLoaded = false;
  String _currentWord = '';
  double _speed = 1.5;
  bool _showWordList = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _requestController = TextEditingController();
  String _statusMsg = '';

  // ── STT (sesle yazma) ──
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _sttAvailable = false;
  bool _isListening = false;

  Future<void> _initStt() async {
    try {
      _sttAvailable = await _speech.initialize(
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') {
            if (mounted) setState(() => _isListening = false);
          }
        },
        onError: (e) {
          if (mounted) setState(() {
            _isListening = false;
            _statusMsg = 'Mikrofon hatası: ${e.errorMsg}';
          });
        },
      );
      if (mounted) setState(() {});
    } catch (e) {
      _sttAvailable = false;
    }
  }

  Future<void> _toggleMic() async {
    if (_isListening) {
      await _speech.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }
    if (!_sttAvailable) {
      await _initStt();
      if (!_sttAvailable) {
        if (mounted) setState(() => _statusMsg = 'Mikrofon kullanılamıyor');
        return;
      }
    }
    setState(() => _isListening = true);
    await _speech.listen(
      localeId: 'tr_TR',
      listenMode: stt.ListenMode.dictation,
      partialResults: true,
      onResult: (r) {
        setState(() {
          _textController.text = r.recognizedWords;
        });
        if (r.finalResult) {
          setState(() => _isListening = false);
          if (r.recognizedWords.trim().isNotEmpty) {
            _translateAndPlay();
          }
        }
      },
    );
  }

  final List<String> _quickPhrases = [
    'Merhaba nasılsın',
    'İyiyim sen ne yapıyorsun',
    'Ben çalışıyorum çok yoruldum',
    'Saat kaçta bitiyor',
    'Akşam beşten sonra boşum',
    'Beraber kahve içelim mi',
    'Tamam nerede buluşalım',
    'Parkın yanındaki kafede',
    'Tamam görüşürüz',
    'Kendine iyi bak',
  ];

  @override
  void initState() {
    super.initState();
    _initWebView();
    _loadKnownWords();
    _initStt();
  }

  Future<void> _initWebView() async {
    final localPort = await LocalServer.start();

    final ctrl = WebViewController();
    ctrl
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0F111A))
      ..addJavaScriptChannel('FlutterBridge', onMessageReceived: (msg) {
        try {
          final data = jsonDecode(msg.message);
          if (data['type'] == 'wordStart') {
            setState(() => _currentWord = data['word'] ?? '');
          } else if (data['type'] == 'done') {
            setState(() { _isPlaying = false; _currentWord = ''; _statusMsg = ''; });
          } else if (data['type'] == 'skip') {
            // word was skipped (not in savedPoses)
          }
        } catch (_) {}
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) {
          setState(() => _isLoaded = true);
          _injectBridge(ctrl);
        },
      ))
      ..setOnConsoleMessage((msg) {
        debugPrint('[AvatarWV] ${msg.message}');
        DebugLog.add('AVATAR', msg.message,
            isError: msg.message.toLowerCase().contains('error'));
      });

    final androidCtrl = ctrl.platform as AndroidWebViewController;
    androidCtrl.setMediaPlaybackRequiresUserGesture(false);

    // hideControls=1 hides mobile input bar etc from HTML
    final url = 'http://127.0.0.1:$localPort/step4_blender_player.html?mobile=1&bright=1&hideControls=1';
    ctrl.loadRequest(Uri.parse(url));

    if (mounted) setState(() => _webController = ctrl);
  }

  void _injectBridge(WebViewController ctrl) {
    ctrl.runJavaScript('''
      window._flutterNotify = function(type, data) {
        if(window.FlutterBridge) FlutterBridge.postMessage(JSON.stringify({type:type, ...data}));
      };
    ''');
    // Set initial speed
    ctrl.runJavaScript('if(document.getElementById("speedRange")) document.getElementById("speedRange").value = $_speed;');
    // Inject local poses if loaded
    _injectPosesToWebView(ctrl);
  }

  Future<void> _injectPosesToWebView(WebViewController ctrl) async {
    // Fetch poses from LocalServer (avoids JS string escaping issues)
    final localPort = LocalServer.port;
    ctrl.runJavaScript('''
      (async function(){
        try {
          const r = await fetch('http://127.0.0.1:$localPort/saved_poses.json');
          const data = await r.json();
          if(typeof loadPoses === 'function') loadPoses(data);
          else if(typeof window.loadPoses === 'function') window.loadPoses(data);
          else { window.savedPoses = data; }
          console.log('[Flutter] Fetched & loaded ' + Object.keys(data).length + ' poses from local server');
        } catch(e) {
          console.error('[Flutter] Pose fetch error:', e);
        }
      })();
    ''');
    DebugLog.add('AVATAR', 'Triggered pose fetch from local server port $localPort');
  }

  Future<void> _loadKnownWords() async {
    // Load from local asset first (always available)
    try {
      final jsonStr = await DefaultAssetBundle.of(context).loadString('assets/saved_poses.json');
      final poses = jsonDecode(jsonStr) as Map<String, dynamic>;
      setState(() => _knownWords = poses.keys.toList()..sort());
    } catch (_) {}

    // Try API for latest (may have new poses)
    try {
      final data = await ApiService.listPoses();
      if (data != null) {
        final poses = data['poses'] ?? data;
        if (poses is Map && poses.isNotEmpty) {
          setState(() => _knownWords = poses.keys.cast<String>().toList()..sort());
        }
      }
    } catch (_) {}
  }

  void _translateAndPlay([String? text]) {
    final input = text ?? _textController.text.trim();
    if (input.isEmpty || _isPlaying) return;
    _focusNode.unfocus();

    final glosses = NlpService.turkishToGloss(input, _knownWords);
    DebugLog.add('AVATAR', 'NLP: "$input" -> ${glosses.join(", ")} (${_knownWords.length} known words)');
    if (glosses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Bilinen kelime bulunamadı'),
          backgroundColor: const Color(0xFFEF4444),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() {
      _isPlaying = true;
      _currentWord = '';
      _statusMsg = glosses.map((g) => NlpService.glossToTR[g] ?? g).join(' → ');
    });

    final glossJson = glosses.map((g) => '"$g"').join(',');
    _webController?.runJavaScript('''
      (async function(){
        const words = [$glossJson];
        for(let i=0; i<words.length; i++){
          const w = words[i];
          if(window._flutterNotify) window._flutterNotify('wordStart', {word: w});
          if(typeof window.mobileSendWord === 'function'){
            await window.mobileSendWord(w);
          } else if(typeof window.playWord === 'function'){
            document.getElementById('glossInput').value = w;
            await window.playWord();
          }
          await new Promise(r => setTimeout(r, 200));
        }
        if(window._flutterNotify) window._flutterNotify('done', {});
      })();
    ''');
  }

  void _playWord(String word) {
    if (_isPlaying) return;
    setState(() { _isPlaying = true; _currentWord = word; _statusMsg = ''; });
    _webController?.runJavaScript('''
      (async function(){
        if(window._flutterNotify) window._flutterNotify('wordStart', {word:'$word'});
        if(typeof window.mobileSendWord === 'function'){
          await window.mobileSendWord('$word');
        } else if(typeof window.playWord === 'function'){
          document.getElementById('glossInput').value='$word';
          await window.playWord();
        }
        if(window._flutterNotify) window._flutterNotify('done', {});
      })();
    ''');
  }

  void _setSpeed(double speed) {
    setState(() => _speed = speed);
    _webController?.runJavaScript('if(typeof setSpeed==="function") setSpeed($speed);');
  }

  void _submitWordRequest() {
    final word = _requestController.text.trim();
    if (word.isEmpty) return;
    ApiService.requestWord(word);
    _requestController.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('"$word" isteği gönderildi'),
        backgroundColor: const Color(0xFF22C55E),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  List<String> get _filteredWords {
    if (_searchQuery.isEmpty) return _knownWords;
    final q = NlpService.normTR(_searchQuery);
    return _knownWords.where((w) => w.contains(q) ||
        (NlpService.glossToTR[w] ?? w).toUpperCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(
          children: [
            // ── Avatar WebView ──
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 16, offset: const Offset(0, 4)),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(
                    children: [
                      if (_webController != null && _isLoaded)
                        WebViewWidget(controller: _webController!)
                      else
                        Container(
                          color: const Color(0xFF0F111A),
                          child: const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(color: Color(0xFF5B4CDB)),
                                SizedBox(height: 12),
                                Text('Avatar yükleniyor...', style: TextStyle(color: Colors.grey, fontSize: 13)),
                              ],
                            ),
                          ),
                        ),

                      // Word count + list button
                      Positioned(
                        top: 10, right: 10,
                        child: GestureDetector(
                          onTap: () => setState(() => _showWordList = !_showWordList),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.92),
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 8)],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.list_rounded, size: 14, color: Color(0xFF5B4CDB)),
                                const SizedBox(width: 4),
                                Text('${_knownWords.length} kelime',
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF5B4CDB))),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // ── Status / gloss translation ──
            if (_statusMsg.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                child: Text(_statusMsg,
                    style: TextStyle(fontSize: 11, color: Colors.grey[500], fontStyle: FontStyle.italic),
                    textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),

            // ── Speed slider ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.speed_rounded, size: 16, color: Color(0xFF5B4CDB)),
                  const SizedBox(width: 4),
                  Text('Hız', style: TextStyle(fontSize: 11, color: Colors.grey[600], fontWeight: FontWeight.w600)),
                  Expanded(
                    child: SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                        activeTrackColor: const Color(0xFF5B4CDB),
                        inactiveTrackColor: const Color(0xFF5B4CDB).withValues(alpha: 0.12),
                        thumbColor: const Color(0xFF5B4CDB),
                      ),
                      child: Slider(
                        value: _speed, min: 0.3, max: 3.0, divisions: 27,
                        onChanged: _setSpeed,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF5B4CDB).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('${_speed.toStringAsFixed(1)}x',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF5B4CDB), fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),

            // ── Quick phrases ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
              child: SizedBox(
                height: 34,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _quickPhrases.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: GestureDetector(
                      onTap: () => _translateAndPlay(_quickPhrases[i]),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: const Color(0xFF5B4CDB).withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF5B4CDB).withValues(alpha: 0.18)),
                        ),
                        child: Text(_quickPhrases[i], style: const TextStyle(fontSize: 12,
                            color: Color(0xFF5B4CDB), fontWeight: FontWeight.w500)),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ── Input bar ──
            Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, MediaQuery.of(context).padding.bottom + 8),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE5E7EB)),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8)],
                      ),
                      child: TextField(
                        controller: _textController,
                        focusNode: _focusNode,
                        decoration: InputDecoration(
                          hintText: 'Cümle yazın... (ör: bugün evdeydim)',
                          hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                        ),
                        style: const TextStyle(color: Color(0xFF1A1A2E), fontSize: 15),
                        onSubmitted: (_) => _translateAndPlay(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Mikrofon — sesle yazma
                  GestureDetector(
                    onTap: _isPlaying ? null : _toggleMic,
                    child: Container(
                      width: 48, height: 48,
                      decoration: BoxDecoration(
                        gradient: _isListening
                            ? const LinearGradient(colors: [Color(0xFFEF4444), Color(0xFFDC2626)])
                            : const LinearGradient(colors: [Color(0xFF06B6D4), Color(0xFF0891B2)]),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: (_isListening ? const Color(0xFFEF4444) : const Color(0xFF06B6D4)).withValues(alpha: 0.35),
                            blurRadius: 12, offset: const Offset(0, 4),
                          )
                        ],
                      ),
                      child: Icon(
                        _isListening ? Icons.stop : Icons.mic,
                        color: Colors.white, size: 22,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _isPlaying ? null : () => _translateAndPlay(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      decoration: BoxDecoration(
                        gradient: _isPlaying ? null : const LinearGradient(
                          colors: [Color(0xFF5B4CDB), Color(0xFF8B7EF8)],
                        ),
                        color: _isPlaying ? Colors.grey[300] : null,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: _isPlaying ? null : [
                          BoxShadow(color: const Color(0xFF5B4CDB).withValues(alpha: 0.25), blurRadius: 8, offset: const Offset(0, 2)),
                        ],
                      ),
                      child: _isPlaying
                          ? const SizedBox(width: 20, height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Çevir', style: TextStyle(color: Colors.white,
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        // ── Word list drawer ──
        if (_showWordList) ...[
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _showWordList = false),
              child: Container(color: Colors.black.withValues(alpha: 0.35)),
            ),
          ),
          Positioned(
            top: 0, right: 0, bottom: 0, width: 280,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 20)],
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          const Text('Kelimeler', style: TextStyle(color: Color(0xFF1A1A2E),
                              fontSize: 17, fontWeight: FontWeight.w700)),
                          const Spacer(),
                          GestureDetector(
                            onTap: () => setState(() => _showWordList = false),
                            child: const Icon(Icons.close_rounded, color: Colors.grey, size: 22),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: TextField(
                        controller: _searchController,
                        onChanged: (v) => setState(() => _searchQuery = v),
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'Kelime ara...',
                          hintStyle: TextStyle(color: Colors.grey[400]),
                          filled: true,
                          fillColor: const Color(0xFFF3F4F6),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          prefixIcon: Icon(Icons.search, color: Colors.grey[400], size: 18),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        itemCount: _filteredWords.length,
                        itemBuilder: (_, i) {
                          final w = _filteredWords[i];
                          final display = NlpService.glossToTR[w] ?? w;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: GestureDetector(
                              onTap: () {
                                _playWord(w);
                                setState(() => _showWordList = false);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF8F8FC),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  children: [
                                    Text(display, style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A2E))),
                                    const Spacer(),
                                    Icon(Icons.play_circle_outline_rounded, size: 18, color: Colors.grey[400]),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(border: Border(top: BorderSide(color: Colors.grey[200]!))),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Kelime İsteği', style: TextStyle(color: Colors.grey[500],
                              fontSize: 11, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _requestController,
                                  style: const TextStyle(fontSize: 13),
                                  decoration: InputDecoration(
                                    hintText: 'Yeni kelime iste...',
                                    hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
                                    filled: true,
                                    fillColor: const Color(0xFFF3F4F6),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: _submitWordRequest,
                                child: Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF5B4CDB),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(Icons.send_rounded, color: Colors.white, size: 16),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  @override
  void dispose() {
    try { _speech.stop(); } catch (_) {}
    _textController.dispose();
    _focusNode.dispose();
    _searchController.dispose();
    _requestController.dispose();
    super.dispose();
  }
}

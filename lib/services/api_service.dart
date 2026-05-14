import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  static String serverIP = '192.168.1.28';
  static int mainPort = 5050;
  // Faz B: GRU'yu telefonda calistir (sunucu sadece MediaPipe yapar)
  // true -> ws_frame_lm yolunu kullan, ONNX inference telefonda
  // false -> ws_frame (tamamen sunucuda — Phase A, web ile birebir ayni pipeline)
  //
  // ─── TEŞHİS: Phase A zorlandi ───
  // Phase B'de model BARIŞ'a kilitleniyor (FPS=8 + Dart normalize + ONNX kombosu
  // dağılım dışı landmark uretiyor). Phase A'da sunucu hem holistic hem inference
  // yapar — webin yaptigi tam pipeline. Telefon sadece JPEG yollar, hicbir Dart
  // landmark hesaplamasi yok.
  static bool localInferenceMode = false;

  static String get mainBaseUrl => 'http://$serverIP:$mainPort';

  /// Load saved server IP from SharedPreferences
  static Future<void> loadSavedIP() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIP = prefs.getString('server_ip');
      final savedPort = prefs.getInt('server_port');
      final savedLocal = prefs.getBool('local_inference');
      if (savedIP != null && savedIP.isNotEmpty) {
        serverIP = savedIP;
      }
      if (savedPort != null) {
        mainPort = savedPort;
      }
      // ─── TEŞHİS BUILD: Saved local_inference flag'i YOKSAY ───
      // Önceki kullanici ayarlarini temizleyip Phase A'yi zorlamak icin.
      // if (savedLocal != null) {
      //   localInferenceMode = savedLocal;
      // }
    } catch (_) {}
  }

  /// Save server IP to SharedPreferences
  static Future<void> saveServerConfig(String ip, int port, {bool? localInference}) async {
    serverIP = ip;
    mainPort = port;
    if (localInference != null) localInferenceMode = localInference;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('server_ip', ip);
      await prefs.setInt('server_port', port);
      if (localInference != null) {
        await prefs.setBool('local_inference', localInference);
      }
    } catch (_) {}
  }

  /// Send camera frame and get prediction
  static Future<Map<String, dynamic>?> predictFrame(String base64Image, {bool flip = false}) async {
    try {
      final response = await http
          .post(
            Uri.parse('$mainBaseUrl/predict_frame'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'image_base64': base64Image, 'flip': flip}),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (_) {}
    return null;
  }

  /// Reset prediction buffer
  static Future<void> resetBuffer() async {
    try {
      await http.post(Uri.parse('$mainBaseUrl/reset_buffer'));
    } catch (_) {}
  }

  /// Get available poses list
  static Future<Map<String, dynamic>?> listPoses() async {
    try {
      final response = await http
          .get(Uri.parse('$mainBaseUrl/api/list-poses'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (_) {}
    return null;
  }

  /// Check server connection (try predict_frame endpoint)
  static Future<bool> checkConnection() async {
    try {
      final response = await http
          .post(
            Uri.parse('$mainBaseUrl/predict_frame'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'image_base64': ''}),
          )
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Submit a word request
  static Future<void> requestWord(String word) async {
    try {
      await http.post(
        Uri.parse('$mainBaseUrl/api/word-request'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'word': word}),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}

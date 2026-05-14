import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'api_service.dart';

class LocalServer {
  static HttpServer? _server;
  static int port = 0;
  static String? _assetDir;

  static Future<int> start() async {
    if (_server != null) return port;

    _assetDir = await _copyAssets();

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = _server!.port;

    _server!.listen((request) async {
      // CORS headers for all responses
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      request.response.headers.set('Access-Control-Allow-Headers', 'Content-Type');

      if (request.method == 'OPTIONS') {
        request.response..statusCode = 200..close();
        return;
      }

      String path = request.uri.path;

      // Pozlar tamamen offline: asset olarak paketlenmis saved_poses.json'u
      // dogrudan dondur (sunucu bagimsizligi icin).
      if (path == '/api/list-poses') {
        await _serveLocalPoses(request);
        return;
      }

      // Diger API'ler sunucuya proxy'lenir (bagli degilse 502)
      if (path == '/predict_frame' || path == '/reset_buffer' ||
          path == '/api/save-pose' || path == '/api/word-request') {
        await _proxyToFlask(request, path);
        return;
      }

      // Serve local files
      if (path == '/') path = '/step4_blender_player.html';

      final filePath = '$_assetDir${path.replaceAll('/', Platform.pathSeparator)}';
      final file = File(filePath);

      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        request.response
          ..statusCode = 200
          ..headers.set('Content-Type', _getMimeType(path))
          ..add(bytes)
          ..close();
      } else {
        request.response
          ..statusCode = 404
          ..write('Not found: $path')
          ..close();
      }
    });

    return port;
  }

  /// saved_poses.json'u HTML'in bekledigi formatta dondur: {"poses": {...}}
  static Future<void> _serveLocalPoses(HttpRequest request) async {
    try {
      final jsonStr = await rootBundle.loadString('assets/saved_poses.json');
      // step4 HTML hem {"poses": {...}} hem dogrudan {...} kabul ediyor;
      // asset zaten {...} formatinda — sarmala.
      final parsed = jsonDecode(jsonStr);
      final payload = jsonEncode({'poses': parsed});
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(payload)
        ..close();
    } catch (e) {
      request.response
        ..statusCode = 500
        ..write('{"error":"local poses load failed: $e"}')
        ..close();
    }
  }

  /// Proxy request to Flask server
  static Future<void> _proxyToFlask(HttpRequest request, String path) async {
    try {
      final flaskUrl = '${ApiService.mainBaseUrl}$path';
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);

      final proxyReq = await client.openUrl(request.method, Uri.parse(flaskUrl));
      proxyReq.headers.set('Content-Type', 'application/json');

      // Forward request body for POST
      if (request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        proxyReq.write(body);
      }

      final proxyResp = await proxyReq.close();
      final respBody = await utf8.decoder.bind(proxyResp).join();

      request.response
        ..statusCode = proxyResp.statusCode
        ..headers.contentType = ContentType.json
        ..write(respBody)
        ..close();

      client.close(force: false);
    } catch (e) {
      request.response
        ..statusCode = 502
        ..write('{"error":"proxy failed: $e"}')
        ..close();
    }
  }

  static Future<String> _copyAssets() async {
    final tempDir = await getTemporaryDirectory();
    final dir = Directory('${tempDir.path}/avatar_assets');
    // Always recreate to get latest files
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);

    // Copy avatar HTML
    final avatarHtml = await rootBundle.loadString('assets/avatar/step4_blender_player.html');
    await File('${dir.path}/step4_blender_player.html').writeAsString(avatarHtml);

    // Copy camera HTML
    final cameraHtml = await rootBundle.loadString('assets/avatar/mobile.html');
    await File('${dir.path}/mobile.html').writeAsString(cameraHtml);

    // Copy GLB
    final glbData = await rootBundle.load('assets/avatar/rain.glb');
    await File('${dir.path}/rain.glb').writeAsBytes(
        glbData.buffer.asUint8List(glbData.offsetInBytes, glbData.lengthInBytes));

    // Copy saved poses
    final poses = await rootBundle.loadString('assets/saved_poses.json');
    await File('${dir.path}/saved_poses.json').writeAsString(poses);

    // Copy manifest if exists
    try {
      final manifest = await rootBundle.loadString('assets/avatar/manifest.json');
      await File('${dir.path}/manifest.json').writeAsString(manifest);
    } catch (_) {}

    return dir.path;
  }

  static String _getMimeType(String path) {
    if (path.endsWith('.html')) return 'text/html; charset=utf-8';
    if (path.endsWith('.js')) return 'application/javascript';
    if (path.endsWith('.json')) return 'application/json';
    if (path.endsWith('.glb')) return 'model/gltf-binary';
    if (path.endsWith('.css')) return 'text/css';
    if (path.endsWith('.png')) return 'image/png';
    return 'application/octet-stream';
  }

  static Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}

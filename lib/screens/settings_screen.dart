import 'package:flutter/material.dart';
import '../services/api_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _ipController;
  late TextEditingController _portController;
  bool _isTesting = false;
  bool? _testResult;
  late bool _localInference;

  @override
  void initState() {
    super.initState();
    _ipController = TextEditingController(text: ApiService.serverIP);
    _portController = TextEditingController(text: ApiService.mainPort.toString());
    _localInference = ApiService.localInferenceMode;
  }

  Future<void> _testConnection() async {
    setState(() { _isTesting = true; _testResult = null; });
    final oldIP = ApiService.serverIP;
    final oldPort = ApiService.mainPort;
    ApiService.serverIP = _ipController.text.trim();
    ApiService.mainPort = int.tryParse(_portController.text.trim()) ?? 8000;
    final result = await ApiService.checkConnection();
    if (!result) { ApiService.serverIP = oldIP; ApiService.mainPort = oldPort; }
    if (mounted) setState(() { _isTesting = false; _testResult = result; });
  }

  Future<void> _saveSettings() async {
    await ApiService.saveServerConfig(
        _ipController.text.trim(),
        int.tryParse(_portController.text.trim()) ?? 8000,
        localInference: _localInference);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: const Text('Ayarlar kaydedildi'),
            backgroundColor: const Color(0xFF5B4CDB),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('Ayarlar'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Server connection card
          Container(
            padding: const EdgeInsets.all(20),
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
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF5B4CDB).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.dns_rounded, color: Color(0xFF5B4CDB), size: 20),
                    ),
                    const SizedBox(width: 12),
                    const Text('Sunucu Baglantisi',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF1A1A2E))),
                  ],
                ),
                const SizedBox(height: 6),
                Text('Bilgisayardaki SignBridge sunucusunun IP ve portunu girin.',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                const SizedBox(height: 16),

                // IP field
                Text('IP Adresi', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey[600])),
                const SizedBox(height: 6),
                TextField(
                  controller: _ipController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  decoration: InputDecoration(
                    hintText: '192.168.1.28',
                    hintStyle: TextStyle(color: Colors.grey[400]),
                    filled: true, fillColor: const Color(0xFFF7F7FA),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF5B4CDB))),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
                const SizedBox(height: 12),

                // Port field
                Text('Port', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey[600])),
                const SizedBox(height: 6),
                TextField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  decoration: InputDecoration(
                    hintText: '8000',
                    hintStyle: TextStyle(color: Colors.grey[400]),
                    filled: true, fillColor: const Color(0xFFF7F7FA),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF5B4CDB))),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
                const SizedBox(height: 16),

                // Test button
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _isTesting ? null : _testConnection,
                    icon: _isTesting
                        ? const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF5B4CDB)))
                        : Icon(_testResult == null ? Icons.speed : (_testResult! ? Icons.check_circle : Icons.error),
                            size: 18),
                    label: Text(_isTesting ? 'Test ediliyor...' : 'Baglantiyi Test Et'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF5B4CDB),
                      side: const BorderSide(color: Color(0xFF5B4CDB)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),

                if (_testResult != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: (_testResult! ? const Color(0xFF10B981) : const Color(0xFFEF4444)).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(_testResult! ? Icons.check_circle : Icons.error,
                            color: _testResult! ? const Color(0xFF10B981) : const Color(0xFFEF4444), size: 18),
                        const SizedBox(width: 8),
                        Expanded(child: Text(
                            _testResult! ? 'Baglanti basarili!' : 'Baglanti kurulamadi.',
                            style: TextStyle(fontSize: 13,
                                color: _testResult! ? const Color(0xFF10B981) : const Color(0xFFEF4444)))),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 16),

                // Save button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _saveSettings,
                    icon: const Icon(Icons.save_rounded, size: 18),
                    label: const Text('Kaydet', style: TextStyle(fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF5B4CDB),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      elevation: 0,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Inference mode card (Faz B)
          Container(
            padding: const EdgeInsets.all(20),
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
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.memory_rounded, color: Color(0xFF10B981), size: 20),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text('Çeviri Motoru',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF1A1A2E))),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  activeThumbColor: const Color(0xFF10B981),
                  value: _localInference,
                  onChanged: (v) => setState(() => _localInference = v),
                  title: Text(
                    _localInference ? 'Telefonda (hızlı)' : 'Sunucuda',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    _localInference
                        ? 'GRU telefonda, ağ yükü %90 daha az'
                        : 'Tüm işlem PC sunucusunda',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Help card
          Container(
            padding: const EdgeInsets.all(16),
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
                    Icon(Icons.help_outline, size: 16, color: Colors.grey[500]),
                    const SizedBox(width: 6),
                    Text('IP adresi nasil bulunur?',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey[600])),
                  ],
                ),
                const SizedBox(height: 10),
                _step('1', 'Bilgisayarda CMD acin'),
                _step('2', 'ipconfig yazin'),
                _step('3', 'IPv4 Address satirindaki IP\'yi kopyalayin'),
                _step('4', 'Telefon ayni WiFi aginda olmali'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _step(String num, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(
            width: 20, height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF5B4CDB).withValues(alpha: 0.1),
            ),
            child: Center(child: Text(num, style: const TextStyle(fontSize: 10,
                color: Color(0xFF5B4CDB), fontWeight: FontWeight.w700))),
          ),
          const SizedBox(width: 8),
          Text(text, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }
}

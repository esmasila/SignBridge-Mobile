import 'package:flutter/material.dart';

/// Global debug log buffer
class DebugLog {
  static final List<DebugEntry> _entries = [];
  static final List<VoidCallback> _listeners = [];
  static const int maxEntries = 500;

  static List<DebugEntry> get entries => _entries;

  static void add(String source, String message, {bool isError = false}) {
    _entries.insert(0, DebugEntry(
      time: DateTime.now(),
      source: source,
      message: message,
      isError: isError,
    ));
    if (_entries.length > maxEntries) _entries.removeLast();
    for (final l in _listeners) { l(); }
  }

  static void addListener(VoidCallback cb) => _listeners.add(cb);
  static void removeListener(VoidCallback cb) => _listeners.remove(cb);
  static void clear() { _entries.clear(); for (final l in _listeners) { l(); } }
}

class DebugEntry {
  final DateTime time;
  final String source;
  final String message;
  final bool isError;
  DebugEntry({required this.time, required this.source, required this.message, this.isError = false});

  String get timeStr => '${time.hour.toString().padLeft(2,'0')}:${time.minute.toString().padLeft(2,'0')}:${time.second.toString().padLeft(2,'0')}';
}

class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  String _filter = '';

  @override
  void initState() {
    super.initState();
    DebugLog.addListener(_onNewLog);
  }

  void _onNewLog() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    DebugLog.removeListener(_onNewLog);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filter.isEmpty
        ? DebugLog.entries
        : DebugLog.entries.where((e) =>
            e.source.toLowerCase().contains(_filter.toLowerCase()) ||
            e.message.toLowerCase().contains(_filter.toLowerCase())).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Console'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: () { DebugLog.clear(); setState(() {}); },
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Filtrele... (cam, avatar, api, error)',
                hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
                filled: true,
                fillColor: const Color(0xFFF3F4F6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                prefixIcon: Icon(Icons.search, color: Colors.grey[400], size: 18),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          // Stats
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text('${filtered.length} log', style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                const Spacer(),
                Text(
                  '${DebugLog.entries.where((e) => e.isError).length} hata',
                  style: const TextStyle(fontSize: 11, color: Color(0xFFEF4444), fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const Divider(height: 8),
          // Log list
          Expanded(
            child: filtered.isEmpty
                ? Center(child: Text('Log yok', style: TextStyle(color: Colors.grey[400])))
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final e = filtered[i];
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: e.isError ? const Color(0xFFEF4444).withValues(alpha: 0.05) : null,
                          border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.timeStr,
                                style: TextStyle(fontSize: 9, color: Colors.grey[400],
                                    fontFamily: 'monospace')),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: _sourceColor(e.source).withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(e.source,
                                  style: TextStyle(fontSize: 9, color: _sourceColor(e.source),
                                      fontWeight: FontWeight.w600)),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(e.message,
                                  style: TextStyle(fontSize: 11,
                                      color: e.isError ? const Color(0xFFEF4444) : const Color(0xFF1A1A2E),
                                      fontFamily: 'monospace'),
                                  maxLines: 4, overflow: TextOverflow.ellipsis),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Color _sourceColor(String source) {
    switch (source) {
      case 'CAM': return const Color(0xFF22C55E);
      case 'AVATAR': return const Color(0xFF5B4CDB);
      case 'API': return const Color(0xFFF59E0B);
      case 'SERVER': return const Color(0xFF3B82F6);
      case 'ERROR': return const Color(0xFFEF4444);
      default: return Colors.grey;
    }
  }
}

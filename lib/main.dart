import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;

void main() => runApp(const RoadvertApp());

class RoadvertApp extends StatelessWidget {
  const RoadvertApp({super.key});

  // You can tweak these to your exact brand colors:
  static const Color roadvertRed = Color(0xFFE53935);
  static const Color roadvertBlue = Color(0xFF1E88E5);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Roadvert Scanner',
      theme: ThemeData(
        scaffoldBackgroundColor: roadvertBlue,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 1,
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Color.fromARGB(255, 255, 255, 255),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: roadvertBlue,
            textStyle: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: roadvertRed),
            textStyle: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ),
      home: const ScannerPage(),
    );
  }
}

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});
  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final List<_BeaconInfo> _beacons = [];
  final Set<String> _seenUrls = {};
  bool _scanning = false;
  StreamSubscription<List<ScanResult>>? _scanSub;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }

  Future<bool> _ensurePermissions() async {
    final s = await Permission.bluetoothScan.request();
    final c = await Permission.bluetoothConnect.request();
    final l = await Permission.location.request();
    return s.isGranted && c.isGranted && l.isGranted;
  }

  Future<void> _startScan() async {
    if (!await _ensurePermissions()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Permissions required to scan')),
      );
      return;
    }

    setState(() {
      _scanning = true;
      _beacons.clear();
      _seenUrls.clear();
    });

    FlutterBluePlus.stopScan();
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final url = _extractEddystoneUrl(r);
        // ← duplicate check here
        if (url != null && !_seenUrls.contains(url)) {
          _seenUrls.add(url); // ← mark as “in flight”
          _fetchMetadata(url).then((info) {
            if (!mounted) return;
            setState(() => _beacons.add(info));
          });
        }
      }
    });

    Future.delayed(const Duration(seconds: 10), () {
      FlutterBluePlus.stopScan();
      if (!mounted) return;
      setState(() => _scanning = false);
    });
  }

  // Parse the Eddystone-URL frame
  String? _extractEddystoneUrl(ScanResult r) {
    final svc = Guid('0000FEAA-0000-1000-8000-00805F9B34FB');
    final data = r.advertisementData.serviceData[svc];
    if (data == null || data.isEmpty) return null;
    if (data[0] != 0x10) return null; // not a URL frame

    final payload = data.sublist(2);
    if (payload.isEmpty) return null;

    const prefixes = {
      0x00: 'http://www.',
      0x01: 'https://www.',
      0x02: 'http://',
      0x03: 'https://',
    };
    final scheme = prefixes[payload[0]] ?? '';
    final rest = payload.sublist(1).map((b) {
      switch (b) {
        case 0x00:
          return '.com/';
        case 0x01:
          return '.org/';
        case 0x02:
          return '.edu/';
        case 0x03:
          return '.net/';
        case 0x04:
          return '.info/';
        case 0x05:
          return '.biz/';
        case 0x06:
          return '.gov/';
        case 0x07:
          return '.com';
        default:
          return String.fromCharCode(b);
      }
    }).join();
    return scheme + rest;
  }

  // Fetch <title> and meta description (and optionally og:image)
  Future<_BeaconInfo> _fetchMetadata(String url) async {
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) throw Exception();
      final doc = html_parser.parse(utf8.decode(res.bodyBytes));

      final title = doc
              .querySelector('meta[property="og:title"]')
              ?.attributes['content']
              ?.trim() ??
          doc.querySelector('title')?.text.trim() ??
          url;

      final desc = doc
              .querySelector('meta[name="description"]')
              ?.attributes['content']
              ?.trim() ??
          '';

      final img = doc
          .querySelector('meta[property="og:image"]')
          ?.attributes['content']
          ?.trim();

      return _BeaconInfo(
        url: url,
        title: title,
        description: desc,
        imageUrl: img,
      );
    } catch (_) {
      return _BeaconInfo(url: url, title: url, description: '', imageUrl: null);
    }
  }

  // Build a Google favicon URL
  String _faviconUrl(String url) {
    final host = Uri.parse(url).host;
    return 'https://www.google.com/s2/favicons?sz=64&domain=$host';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 80,
        elevation: 2,
        backgroundColor: Colors.white,
        leadingWidth: 160,
        leading: Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Image.asset(
            'assets/images/logo-roadvert.png',
            fit: BoxFit.contain,
          ),
        ),
      ),
      body: _scanning && _beacons.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 24),
                  const Text(
                    'Scanning the roads… 🚚',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Color.fromARGB(255, 255, 255, 255),
                    ),
                  ),
                ],
              ),
            )
          : _beacons.isEmpty
              ? Center(
                  child: Text(
                    'No beacons found yet.\nTap 🔍 to scan again.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: const Color.fromARGB(255, 255, 255, 255),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  itemCount: _beacons.length,
                  itemBuilder: (ctx, i) {
                    final b = _beacons[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Card(
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Favicon / logo
                              Image.network(
                                _faviconUrl(b.url),
                                width: 64,
                                height: 64,
                                errorBuilder: (_, __, ___) =>
                                    const Icon(Icons.link, size: 64),
                              ),
                              const SizedBox(width: 16),
                              // Metadata column
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      b.title,
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    if (b.description.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Text(b.description),
                                    ],
                                    const SizedBox(height: 8),
                                    Text(
                                      b.url,
                                      style: const TextStyle(
                                        color: Colors.blue,
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Row(
                                      children: [
                                        ElevatedButton(
                                          onPressed: () =>
                                              launchUrl(Uri.parse(b.url)),
                                          child: const Text('Details'),
                                        ),
                                        const SizedBox(width: 16),
                                        OutlinedButton(
                                          onPressed: () {
                                            setState(() {
                                              _beacons.removeAt(i);
                                            });
                                          },
                                          child: const Text('Dismiss'),
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
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _startScan,
        child: Icon(_scanning ? Icons.refresh : Icons.search),
      ),
    );
  }
}

class _BeaconInfo {
  final String url;
  final String title;
  final String description;
  final String? imageUrl;
  _BeaconInfo({
    required this.url,
    required this.title,
    required this.description,
    this.imageUrl,
  });
}

// SaFoDi - Save From Disaster
// Pendeteksi getaran (akselerometer) + data gempa/tsunami BMKG.
//
// CATATAN: Sensor HP BUKAN alat peringatan dini resmi. Selalu rujuk info resmi BMKG.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const String kBmkgUrl = 'https://data.bmkg.go.id/DataMKG/TEWS/autogempa.json';

final FlutterLocalNotificationsPlugin notifPlugin =
    FlutterLocalNotificationsPlugin();

// ---------------------------------------------------------------------------
// Foreground service (hanya untuk menjaga proses tetap hidup saat layar mati)
// ---------------------------------------------------------------------------

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(KeepAliveTaskHandler());
}

class KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

// ---------------------------------------------------------------------------
// Model & service BMKG
// ---------------------------------------------------------------------------

class EarthquakeData {
  EarthquakeData({
    required this.magnitude,
    required this.depth,
    required this.location,
    required this.region,
    required this.time,
    required this.potensi,
  });

  final String magnitude;
  final String depth;
  final String location; // koordinat
  final String region; // wilayah
  final String time;
  final String potensi; // teks asli dari BMKG

  bool get isTsunami {
    final p = potensi.toLowerCase();
    return p.contains('tsunami') && !p.contains('tidak');
  }

  String get tsunamiLabel {
    if (isTsunami) return 'BERPOTENSI TSUNAMI';
    final p = potensi.toLowerCase();
    if (p.contains('tidak') && p.contains('tsunami')) {
      return 'Tidak berpotensi tsunami';
    }
    return potensi.isEmpty ? 'Status tsunami tidak tersedia' : potensi;
  }

  factory EarthquakeData.fromJson(Map<String, dynamic> json) {
    final g = (json['Infogempa']?['gempa'] ?? {}) as Map<String, dynamic>;
    String s(String k) => (g[k] ?? '-').toString();
    return EarthquakeData(
      magnitude: s('Magnitude'),
      depth: s('Kedalaman'),
      location: '${s('Lintang')}, ${s('Bujur')}',
      region: s('Wilayah'),
      time: '${s('Tanggal')} ${s('Jam')}',
      potensi: (g['Potensi'] ?? '').toString(),
    );
  }
}

Future<EarthquakeData> fetchLatestQuake() async {
  final res = await http
      .get(Uri.parse(kBmkgUrl))
      .timeout(const Duration(seconds: 12));
  if (res.statusCode != 200) {
    throw Exception('BMKG membalas status ${res.statusCode}');
  }
  return EarthquakeData.fromJson(
      jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
}

// ---------------------------------------------------------------------------
// Notifikasi
// ---------------------------------------------------------------------------

Future<void> showQuakeNotification(EarthquakeData q) async {
  final String title;
  final String body;
  if (q.isTsunami) {
    title = '🚨 PERINGATAN TSUNAMI: Gempa M ${q.magnitude} - '
        'Segera Evakuasi ke Tempat Tinggi!';
    body = '${q.region}\n${q.time} • Kedalaman ${q.depth}\n'
        'Status: ${q.tsunamiLabel}';
  } else {
    title = '📳 Getaran terdeteksi • BMKG terakhir: M ${q.magnitude}';
    body = '${q.region}\n${q.time} • Kedalaman ${q.depth}\n'
        'Status: ${q.tsunamiLabel}';
  }
  await _showNotification(title, body);
}

Future<void> _showNotification(String title, String body) async {
  final details = NotificationDetails(
    android: AndroidNotificationDetails(
      'safodi_alert',
      'Peringatan Gempa & Tsunami',
      channelDescription: 'Notifikasi hasil deteksi getaran dan data BMKG',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
      styleInformation: BigTextStyleInformation(body),
    ),
  );
  await notifPlugin.show(1001, title, body, details);
}

// ---------------------------------------------------------------------------
// Sirine: dibuat langsung sebagai WAV di memori (tanpa file asset)
// ---------------------------------------------------------------------------

Uint8List buildSirenWav() {
  const sampleRate = 16000;
  const seconds = 2;
  const n = sampleRate * seconds;
  final data = ByteData(44 + n * 2);

  void writeStr(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(off + i, s.codeUnitAt(i));
    }
  }

  writeStr(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  writeStr(8, 'WAVE');
  writeStr(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // mono
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  writeStr(36, 'data');
  data.setUint32(40, n * 2, Endian.little);

  double phase = 0;
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final x = t % 1.0;
    final tri = x < 0.5 ? x * 2 : (1 - x) * 2; // sapuan naik-turun tiap 1 dtk
    final freq = 700 + 900 * tri;
    phase += 2 * pi * freq / sampleRate;
    final v = (sin(phase) + 0.3 * sin(2 * phase)) / 1.3;
    final sample = (v * 32000).round().clamp(-32768, 32767);
    data.setInt16(44 + i * 2, sample, Endian.little);
  }
  return data.buffer.asUint8List();
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  await notifPlugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  runApp(const SafodiApp());
}

class SafodiApp extends StatelessWidget {
  const SafodiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SaFoDi',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.redAccent,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const int _maxPoints = 100;

  final AudioPlayer _player = AudioPlayer();
  late final Uint8List _sirenBytes;
  StreamSubscription<AccelerometerEvent>? _sub;

  bool _monitoring = false;
  bool _keepAwake = false;
  bool _alarmActive = false;
  bool _loadingQuake = false;
  double _threshold = 12.5;
  double _current = 0;
  final List<double> _history = [];
  EarthquakeData? _quake;
  String? _quakeError;
  DateTime? _cooldownUntil;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sirenBytes = buildSirenWav();
    _initForegroundTask();
    _initAudio();
    _fetchQuake(); // tampilkan data BMKG terakhir saat app dibuka
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'safodi_foreground',
        channelName: 'SaFoDi Berjaga',
        channelDescription: 'SaFoDi memantau getaran di latar belakang',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true, // partial wake lock agar CPU tidak tidur
        allowWifiLock: false,
      ),
    );
  }

  Future<void> _initAudio() async {
    await _player.setAudioContext(
      AudioContext(
        android: AudioContextAndroid(
          usageType: AndroidUsageType.alarm,
          contentType: AndroidContentType.sonification,
          audioFocus: AndroidAudioFocus.gain,
          stayAwake: true,
        ),
      ),
    );
    await _player.setReleaseMode(ReleaseMode.loop);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _player.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // Mode OFF: sensor hanya aktif saat aplikasi tampil di layar.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_monitoring) return;
    if (state == AppLifecycleState.resumed) {
      if (_sub == null) _subscribe();
    } else if (state == AppLifecycleState.paused &&
        !_keepAwake &&
        !_alarmActive) {
      _unsubscribe();
    }
  }

  // ------------------------------ Sensor ----------------------------------

  void _subscribe() {
    _sub?.cancel();
    _sub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 55), // ~18 Hz
    ).listen(
      _onAccel,
      onError: (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sensor akselerometer tidak tersedia')),
        );
      },
    );
  }

  void _unsubscribe() {
    _sub?.cancel();
    _sub = null;
  }

  void _onAccel(AccelerometerEvent e) {
    final total = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    _history.add(total);
    if (_history.length > _maxPoints) _history.removeAt(0);
    if (mounted) setState(() => _current = total);

    if (total > _threshold && !_alarmActive) {
      final cd = _cooldownUntil;
      if (cd == null || DateTime.now().isAfter(cd)) {
        _triggerAlarm();
      }
    }
  }

  // ------------------------------ Alarm -----------------------------------

  Future<void> _triggerAlarm() async {
    setState(() => _alarmActive = true);
    await WakelockPlus.enable(); // jaga layar menyala saat alarm
    try {
      await _player.play(
        BytesSource(_sirenBytes, mimeType: 'audio/wav'),
        volume: 1.0,
      );
    } catch (_) {}
    await _fetchQuake(notify: true);
  }

  Future<void> _stopAlarm() async {
    await _player.stop();
    _cooldownUntil = DateTime.now().add(const Duration(seconds: 30));
    if (mounted) setState(() => _alarmActive = false);
    await _syncWakelock();
  }

  Future<void> _syncWakelock() async {
    if (_monitoring && _keepAwake) {
      await WakelockPlus.enable();
    } else {
      await WakelockPlus.disable();
    }
  }

  // ------------------------------ BMKG ------------------------------------

  Future<void> _fetchQuake({bool notify = false}) async {
    if (mounted) {
      setState(() {
        _loadingQuake = true;
        _quakeError = null;
      });
    }
    try {
      final q = await fetchLatestQuake();
      if (mounted) setState(() => _quake = q);
      if (notify) await showQuakeNotification(q);
    } catch (e) {
      if (mounted) {
        setState(() => _quakeError = 'Gagal mengambil data BMKG: $e');
      }
      if (notify) {
        await _showNotification(
          '📳 Getaran terdeteksi',
          'Data BMKG tidak dapat diambil. Periksa koneksi internet dan '
              'cek info resmi BMKG.',
        );
      }
    } finally {
      if (mounted) setState(() => _loadingQuake = false);
    }
  }

  // --------------------------- Kontrol utama ------------------------------

  Future<void> _toggleMonitoring() async {
    if (_monitoring) {
      _unsubscribe();
      setState(() => _monitoring = false);
    } else {
      await notifPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      setState(() => _monitoring = true);
      _subscribe();
    }
    await _applyBackgroundMode();
  }

  Future<void> _onKeepAwakeChanged(bool value) async {
    setState(() => _keepAwake = value);
    await _applyBackgroundMode();
  }

  Future<void> _applyBackgroundMode() async {
    if (_monitoring && _keepAwake) {
      final perm = await FlutterForegroundTask.checkNotificationPermission();
      if (perm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
      if (!await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.startService(
          serviceId: 7001,
          notificationTitle: 'SaFoDi sedang berjaga',
          notificationText: 'Memantau getaran meski layar mati',
          callback: startCallback,
        );
      }
    } else {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    }
    await _syncWakelock();
  }

  // ------------------------------- UI -------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SaFoDi • Save From Disaster'),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildMainButton(),
              const SizedBox(height: 12),
              _buildKeepAwakeCard(),
              const SizedBox(height: 12),
              _buildSensorCard(),
              const SizedBox(height: 12),
              _buildThresholdCard(),
              const SizedBox(height: 12),
              _buildQuakeCard(),
              const SizedBox(height: 16),
              const Text(
                'Sensor HP bukan alat peringatan dini resmi. Data BMKG di atas '
                'adalah gempa terakhir yang dirilis dan belum tentu gempa yang '
                'baru Anda rasakan. Selalu pantau info resmi BMKG.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
          ),
          if (_alarmActive) _buildAlarmOverlay(),
        ],
      ),
    );
  }

  Widget _buildMainButton() {
    return SizedBox(
      height: 64,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor:
              _monitoring ? Colors.grey.shade700 : Colors.redAccent,
          foregroundColor: Colors.white,
        ),
        onPressed: _toggleMonitoring,
        icon: Icon(_monitoring ? Icons.stop_circle : Icons.shield),
        label: Text(
          _monitoring ? 'Berhenti Berjaga' : 'Mulai Berjaga',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildKeepAwakeCard() {
    return Card(
      child: SwitchListTile(
        value: _keepAwake,
        onChanged: _onKeepAwakeChanged,
        title: const Text('Tetap Berjaga Saat Layar Mati'),
        subtitle: Text(_keepAwake
            ? 'ON • tetap memantau saat layar mati/terkunci'
            : 'OFF • memantau hanya saat aplikasi terbuka'),
        secondary: Icon(_keepAwake ? Icons.nightlight : Icons.phone_android),
      ),
    );
  }

  Widget _buildSensorCard() {
    final over = _current > _threshold;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Getaran Real-time',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _monitoring ? Colors.green : Colors.grey.shade800,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(_monitoring ? 'AKTIF' : 'NONAKTIF',
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${_current.toStringAsFixed(2)} m/s²',
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                color: over ? Colors.redAccent : Colors.cyanAccent,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              width: double.infinity,
              child: CustomPaint(
                painter: _ChartPainter(
                    List<double>.from(_history), _threshold, _maxPoints),
              ),
            ),
            const SizedBox(height: 4),
            const Text('Garis oranye = batas threshold',
                style: TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ),
      ),
    );
  }

  Widget _buildThresholdCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Threshold: ${_threshold.toStringAsFixed(1)} m/s²',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Slider(
              value: _threshold,
              min: 10.5,
              max: 25,
              divisions: 29,
              label: _threshold.toStringAsFixed(1),
              onChanged: (v) => setState(() => _threshold = v),
            ),
            const Text(
              'Makin kecil = makin sensitif. HP diam di meja ≈ 9.8 m/s² '
              '(gravitasi), jadi threshold harus di atas itu.',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuakeCard() {
    final q = _quake;
    final tsunami = q?.isTsunami ?? false;
    return Card(
      color: tsunami ? Colors.red.shade900 : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Data Gempa BMKG Terakhir',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                _loadingQuake
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : IconButton(
                        tooltip: 'Refresh',
                        icon: const Icon(Icons.refresh),
                        onPressed: () => _fetchQuake(),
                      ),
              ],
            ),
            if (_quakeError != null)
              Text(_quakeError!,
                  style: const TextStyle(color: Colors.orangeAccent)),
            if (q == null && _quakeError == null && _loadingQuake)
              const Text('Memuat data...'),
            if (q != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: tsunami
                      ? Colors.red
                      : (q.tsunamiLabel.toLowerCase().contains('tidak')
                          ? Colors.green.shade800
                          : Colors.grey.shade800),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  tsunami
                      ? '⚠️ BERPOTENSI TSUNAMI — Segera evakuasi ke tempat tinggi!'
                      : q.tsunamiLabel,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              _row('Magnitudo', 'M ${q.magnitude}'),
              _row('Kedalaman', q.depth),
              _row('Lokasi', q.location),
              _row('Wilayah', q.region),
              _row('Waktu', q.time),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: const TextStyle(color: Colors.white60)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildAlarmOverlay() {
    final q = _quake;
    return Positioned.fill(
      child: Container(
        color: Colors.red.shade900,
        padding: const EdgeInsets.all(24),
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 96, color: Colors.white),
              const SizedBox(height: 12),
              const Text('GETARAN TERDETEKSI!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: Colors.white)),
              const SizedBox(height: 4),
              Text('${_current.toStringAsFixed(2)} m/s²',
                  style: const TextStyle(fontSize: 18, color: Colors.white70)),
              const SizedBox(height: 20),
              if (_loadingQuake) const CircularProgressIndicator(),
              if (q != null && !_loadingQuake) ...[
                Text(
                  q.isTsunami
                      ? '🚨 BERPOTENSI TSUNAMI\nSegera evakuasi ke tempat tinggi!'
                      : 'BMKG terakhir: M ${q.magnitude}\n${q.tsunamiLabel}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white),
                ),
                const SizedBox(height: 8),
                Text(q.region,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70)),
              ],
              if (_quakeError != null && !_loadingQuake)
                const Text('Data BMKG gagal dimuat',
                    style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 96,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.red.shade900,
                  ),
                  onPressed: _stopAlarm,
                  child: const Text('MATIKAN ALARM',
                      style:
                          TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Grafik getaran
// ---------------------------------------------------------------------------

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.data, this.threshold, this.maxPoints);

  final List<double> data;
  final double threshold;
  final int maxPoints;
  static const double _maxY = 30;

  @override
  void paint(Canvas canvas, Size size) {
    double yOf(double v) =>
        size.height - (min(max(v, 0.0), _maxY) / _maxY) * size.height;

    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final th = Paint()
      ..color = Colors.orangeAccent
      ..strokeWidth = 1.5;
    canvas.drawLine(
        Offset(0, yOf(threshold)), Offset(size.width, yOf(threshold)), th);

    if (data.length < 2) return;
    final step = size.width / (maxPoints - 1);
    final offset = maxPoints - data.length;
    final path = Path();
    for (var i = 0; i < data.length; i++) {
      final x = (offset + i) * step;
      final y = yOf(data[i]);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.cyanAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}

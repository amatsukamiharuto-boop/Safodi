// SaFoDi - Save From Disaster
// Pendeteksi getaran (akselerometer) + data gempa/tsunami BMKG.
//
// CATATAN: Sensor HP BUKAN alat peringatan dini resmi. Selalu rujuk info resmi BMKG.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const String kBmkgUrl = 'https://data.bmkg.go.id/DataMKG/TEWS/autogempa.json';

// Gempa BMKG dianggap "baru" jika terjadi dalam rentang menit ini.
// Peringatan tsunami yang tegas hanya ditampilkan untuk gempa yang baru.
const int kRecentMinutes = 30;

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
    this.occurredAt,
  });

  final String magnitude;
  final String depth;
  final String location; // koordinat
  final String region; // wilayah
  final String time;
  final String potensi; // teks asli dari BMKG
  final DateTime? occurredAt;

  /// Usia kejadian dalam menit (null jika waktu tidak terbaca).
  int? get ageMinutes {
    final t = occurredAt;
    if (t == null) return null;
    final m = DateTime.now().difference(t).inMinutes;
    return m < 0 ? 0 : m;
  }

  /// "Baru" = terjadi dalam kRecentMinutes terakhir.
  /// Jika waktunya tidak terbaca, dianggap baru (lebih aman).
  bool get isRecent {
    final m = ageMinutes;
    return m == null || m <= kRecentMinutes;
  }

  bool get isActiveTsunamiWarning => isTsunami && isRecent;

  String get ageLabel {
    final m = ageMinutes;
    if (m == null) return 'waktu kejadian tidak diketahui';
    if (m < 1) return 'baru saja';
    if (m < 60) return '$m menit lalu';
    if (m < 1440) return '${m ~/ 60} jam lalu';
    return '${m ~/ 1440} hari lalu';
  }

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
      occurredAt: DateTime.tryParse((g['DateTime'] ?? '').toString()),
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
// Riwayat getaran
// ---------------------------------------------------------------------------

String fmtDateTime(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} '
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

class VibrationEvent {
  VibrationEvent({
    required this.time,
    required this.peak,
    required this.threshold,
    this.durationSec = 0,
  });

  final DateTime time;
  double peak;
  final double threshold;
  int durationSec;

  int get level => vibrationLevel(peak);

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'peak': peak,
        'threshold': threshold,
        'durationSec': durationSec,
      };

  factory VibrationEvent.fromJson(Map<String, dynamic> j) => VibrationEvent(
        time: DateTime.tryParse((j['time'] ?? '').toString()) ?? DateTime.now(),
        peak: (j['peak'] as num?)?.toDouble() ?? 0,
        threshold: (j['threshold'] as num?)?.toDouble() ?? 12.5,
        durationSec: (j['durationSec'] as num?)?.toInt() ?? 0,
      );
}

// ---------------------------------------------------------------------------
// Notifikasi
// ---------------------------------------------------------------------------

// Kategori getaran HP berdasarkan selisih dari gravitasi (m/s²).
// Ubah dua angka ini kalau ingin kategori lebih sensitif / lebih longgar.
const double kMediumDyn = 5; // mulai "Sedang"
const double kHighDyn = 10; // mulai "Tinggi" -> Peringatan Darurat

/// 0 = Rendah, 1 = Sedang, 2 = Tinggi
int vibrationLevel(double total) {
  final dyn = total - 9.81;
  if (dyn >= kHighDyn) return 2;
  if (dyn >= kMediumDyn) return 1;
  return 0;
}

String levelLabel(int level) => const ['Rendah', 'Sedang', 'Tinggi'][level];

Color levelColor(int level) => [
      Colors.amber.shade800,
      Colors.deepOrange.shade700,
      Colors.red.shade900,
    ][level];

Future<void> showVibrationNotification(double peak, DateTime time) async {
  final level = vibrationLevel(peak);
  final detail = 'Puncak ${peak.toStringAsFixed(1)} m/s² • ${fmtDateTime(time)}';
  if (level == 2) {
    await _showNotification(
      '🚨 PERINGATAN DARURAT: Getaran TINGGI!',
      '$detail\nSegera lindungi diri dan cari tempat aman.',
    );
  } else {
    await _showNotification(
      '📳 Getaran terdeteksi: ${levelLabel(level)}',
      detail,
    );
  }
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
  double _alarmPeak = 0;
  DateTime? _alarmTime;

  // Pengaturan & riwayat
  SharedPreferences? _prefs;
  double _volume = 1.0;
  int _soundChoice = 0; // 0 = bawaan (alarm.mp3), 1 = sirine klasik, 2 = file sendiri
  String? _customPath;
  String? _customName;
  final List<VibrationEvent> _events = [];
  VibrationEvent? _currentEvent;
  int _tab = 0;
  bool _testing = false;
  Timer? _testTimer;
  Timer? _quakeTimer;
  DateTime? _quakeUpdated;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  bool _emergencyNotified = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sirenBytes = buildSirenWav();
    _initForegroundTask();
    _initAudio();
    _loadSettings();
    _fetchQuake(); // tampilkan data BMKG terakhir saat app dibuka
    _quakeTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (_lifecycle == AppLifecycleState.resumed && !_alarmActive) {
        _fetchQuake();
      }
    });
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
    _testTimer?.cancel();
    _quakeTimer?.cancel();
    _player.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // Mode OFF: sensor hanya aktif saat aplikasi tampil di layar.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (state == AppLifecycleState.resumed) _fetchQuake();
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

    if (_alarmActive && total > _alarmPeak) {
      _alarmPeak = total;
      if (!_emergencyNotified && vibrationLevel(total) == 2) {
        _emergencyNotified = true;
        showVibrationNotification(total, _alarmTime ?? DateTime.now());
      }
    }

    if (total > _threshold && !_alarmActive) {
      final cd = _cooldownUntil;
      if (cd == null || DateTime.now().isAfter(cd)) {
        _triggerAlarm(total);
      }
    }
  }

  // ------------------------------ Alarm -----------------------------------

  Future<void> _triggerAlarm(double peak) async {
    _testTimer?.cancel();
    final ev = VibrationEvent(
      time: DateTime.now(),
      peak: peak,
      threshold: _threshold,
    );
    setState(() {
      _alarmActive = true;
      _alarmPeak = peak;
      _alarmTime = ev.time;
      _currentEvent = ev;
      _emergencyNotified = false;
      _testing = false;
      _tab = 0;
      _events.insert(0, ev);
      if (_events.length > 200) _events.removeRange(200, _events.length);
    });
    _saveHistory();
    await WakelockPlus.enable(); // jaga layar menyala saat alarm
    await _playAlarmSound();

    // Kalau sejak awal sudah Tinggi, langsung kirim notifikasi darurat.
    if (vibrationLevel(peak) == 2) {
      _emergencyNotified = true;
      await showVibrationNotification(peak, ev.time);
    }

    // Tunggu sebentar agar puncak getaran terkumpul, lalu kirim notifikasi.
    await Future.delayed(const Duration(seconds: 2));
    final p = max(ev.peak, _alarmPeak);
    ev.peak = p;
    if (!_emergencyNotified) {
      if (vibrationLevel(p) == 2) _emergencyNotified = true;
      await showVibrationNotification(p, ev.time);
    }
    await _saveHistory();
  }

  Future<void> _stopAlarm() async {
    await _player.stop();
    _cooldownUntil = DateTime.now().add(const Duration(seconds: 30));
    final ev = _currentEvent;
    if (ev != null) {
      ev.peak = max(ev.peak, _alarmPeak);
      ev.durationSec = DateTime.now().difference(ev.time).inSeconds;
    }
    _currentEvent = null;
    if (mounted) setState(() => _alarmActive = false);
    await _saveHistory();
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

  Future<void> _fetchQuake() async {
    if (mounted) {
      setState(() {
        _loadingQuake = true;
        _quakeError = null;
      });
    }
    try {
      final q = await fetchLatestQuake();
      if (mounted) {
        setState(() {
          _quake = q;
          _quakeUpdated = DateTime.now();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _quakeError = 'Gagal mengambil data BMKG: $e');
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
    _saveSettings();
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

  // ------------------- Pengaturan, suara, riwayat -------------------------

  Future<void> _loadSettings() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    final events = <VibrationEvent>[];
    for (final raw in p.getStringList('history') ?? <String>[]) {
      try {
        events.add(
            VibrationEvent.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _volume = p.getDouble('volume') ?? 1.0;
      _soundChoice = p.getInt('soundChoice') ?? 0;
      _customPath = p.getString('customPath');
      _customName = p.getString('customName');
      _threshold = p.getDouble('threshold') ?? 12.5;
      _keepAwake = p.getBool('keepAwake') ?? false;
      _events
        ..clear()
        ..addAll(events);
    });
  }

  Future<void> _saveSettings() async {
    final p = _prefs;
    if (p == null) return;
    await p.setDouble('volume', _volume);
    await p.setInt('soundChoice', _soundChoice);
    await p.setDouble('threshold', _threshold);
    await p.setBool('keepAwake', _keepAwake);
    final cp = _customPath;
    final cn = _customName;
    if (cp != null) await p.setString('customPath', cp);
    if (cn != null) await p.setString('customName', cn);
  }

  Future<void> _saveHistory() async {
    final p = _prefs;
    if (p == null) return;
    await p.setStringList(
      'history',
      _events.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  Source _currentSource() {
    if (_soundChoice == 1) {
      return BytesSource(_sirenBytes, mimeType: 'audio/wav');
    }
    if (_soundChoice == 2) {
      final path = _customPath;
      if (path != null && File(path).existsSync()) {
        return DeviceFileSource(path);
      }
    }
    return AssetSource('alarm.mp3');
  }

  Future<void> _playAlarmSound() async {
    try {
      await _player.play(_currentSource(), volume: _volume);
    } catch (_) {
      // cadangan: sirine buatan kode
      try {
        await _player.play(
          BytesSource(_sirenBytes, mimeType: 'audio/wav'),
          volume: _volume,
        );
      } catch (_) {}
    }
  }

  Future<void> _toggleTest() async {
    if (_testing) {
      await _stopTest();
      return;
    }
    setState(() => _testing = true);
    await _playAlarmSound();
    _testTimer?.cancel();
    _testTimer = Timer(const Duration(seconds: 8), _stopTest);
  }

  Future<void> _stopTest() async {
    _testTimer?.cancel();
    if (!_alarmActive) await _player.stop();
    if (mounted) setState(() => _testing = false);
  }

  Future<void> _pickCustomSound() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.audio);
      final f = result?.files.single;
      final src = f?.path;
      if (f == null || src == null) return;
      final dir = await getApplicationSupportDirectory();
      final dot = f.name.lastIndexOf('.');
      final ext = dot >= 0 ? f.name.substring(dot) : '.mp3';
      final dest = '${dir.path}/custom_alarm$ext';
      final old = _customPath;
      if (old != null && old != dest && File(old).existsSync()) {
        await File(old).delete();
      }
      await File(src).copy(dest);
      if (!mounted) return;
      setState(() {
        _customPath = dest;
        _customName = f.name;
        _soundChoice = 2;
      });
      await _stopTest();
      await _saveSettings();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal memilih file suara: $e')),
      );
    }
  }

  Future<void> _confirmClearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Hapus semua riwayat?'),
        content: const Text('Riwayat getaran akan dihapus permanen dari HP ini.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Batal')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Hapus')),
        ],
      ),
    );
    if (ok == true) {
      setState(() => _events.clear());
      await _saveHistory();
    }
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
          IndexedStack(
            index: _tab,
            sizing: StackFit.expand,
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
          _buildHistoryTab(),
          _buildSettingsTab(),
            ],
          ),
          if (_alarmActive) _buildAlarmOverlay(),
        ],
      ),
      bottomNavigationBar: _alarmActive
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.shield_outlined),
                    selectedIcon: Icon(Icons.shield),
                    label: 'Pantau'),
                NavigationDestination(
                    icon: Icon(Icons.history), label: 'Riwayat'),
                NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: 'Pengaturan'),
              ],
            ),
    );
  }

  Widget _buildHistoryTab() {
    if (_events.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Belum ada riwayat getaran.\n'
            'Getaran yang melewati threshold akan tercatat di sini.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('${_events.length} kejadian tercatat',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            TextButton.icon(
              onPressed: _confirmClearHistory,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Hapus semua'),
            ),
          ],
        ),
        for (final e in _events) _historyCard(e),
        const SizedBox(height: 8),
        const Text(
          'Kategori menunjukkan kekuatan getaran HP, bukan magnitudo gempa.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Colors.white54),
        ),
      ],
    );
  }

  Widget _historyCard(VibrationEvent e) {
    final level = e.level;
    final color = level == 2
        ? Colors.redAccent
        : (level == 1 ? Colors.orangeAccent : Colors.amberAccent);
    return Card(
      child: ExpansionTile(
        leading: Icon(
          level == 2 ? Icons.warning_amber_rounded : Icons.vibration,
          color: color,
        ),
        title: Text('${levelLabel(level)} • ${e.peak.toStringAsFixed(2)} m/s²'),
        subtitle: Text(fmtDateTime(e.time)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('Kategori', levelLabel(level)),
          _row('Puncak', '${e.peak.toStringAsFixed(2)} m/s²'),
          _row('Threshold', '${e.threshold.toStringAsFixed(1)} m/s²'),
          _row('Alarm', '${e.durationSec} detik'),
        ],
      ),
    );
  }

  Widget _buildSettingsTab() {
    Widget soundTile(int idx, String title, String subtitle) {
      final selected = _soundChoice == idx;
      return ListTile(
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? Colors.redAccent : Colors.white54,
        ),
        title: Text(title),
        subtitle: Text(subtitle),
        onTap: () async {
          if (idx == 2 && _customPath == null) {
            await _pickCustomSound();
            return;
          }
          setState(() => _soundChoice = idx);
          await _stopTest();
          await _saveSettings();
        },
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Volume Alarm: ${(_volume * 100).round()}%',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
                Slider(
                  value: _volume,
                  min: 0.1,
                  max: 1.0,
                  divisions: 9,
                  label: '${(_volume * 100).round()}%',
                  onChanged: (v) {
                    setState(() => _volume = v);
                    _player.setVolume(v);
                  },
                  onChangeEnd: (_) => _saveSettings(),
                ),
                const Text(
                  'Volume ini relatif terhadap volume alarm di HP. '
                  'Naikkan juga volume alarm HP (bukan volume media) '
                  'agar sirine benar-benar keras.',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: _toggleTest,
                  icon: Icon(_testing ? Icons.stop : Icons.play_arrow),
                  label: Text(_testing ? 'Hentikan tes' : 'Tes suara alarm'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text('Suara Alarm',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                soundTile(0, 'Alarm Gempa (bawaan)',
                    'Nada peringatan + gemuruh gempa'),
                soundTile(1, 'Sirine klasik', 'Sapuan nada naik-turun'),
                soundTile(
                    2,
                    'File suara dari HP',
                    _customName ??
                        'Belum dipilih — ketuk untuk memilih file'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: OutlinedButton.icon(
                    onPressed: _pickCustomSound,
                    icon: const Icon(Icons.folder_open),
                    label: Text(_customName == null
                        ? 'Pilih file suara dari HP'
                        : 'Ganti file suara'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Pilihan suara dan volume tersimpan di HP dan dipakai saat alarm '
          'berbunyi.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Colors.white54),
        ),
      ],
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
              onChangeEnd: (_) => _saveSettings(),
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
    final tsunami = q?.isActiveTsunamiWarning ?? false;
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
            if (_quakeUpdated != null)
              Text(
                  'Diperbarui ${fmtDateTime(_quakeUpdated!)} • otomatis tiap 2 menit',
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
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
                      : (q.isTsunami
                          ? 'Berpotensi tsunami — kejadian ${q.ageLabel}'
                          : q.tsunamiLabel),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              _row('Magnitudo', 'M ${q.magnitude}'),
              _row('Kedalaman', q.depth),
              _row('Lokasi', q.location),
              _row('Wilayah', q.region),
              _row('Waktu', q.time),
              _row('Terjadi', q.ageLabel),
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
    final level = vibrationLevel(_alarmPeak);
    final t = _alarmTime;
    final hms = t == null
        ? ''
        : '${t.hour.toString().padLeft(2, '0')}:'
            '${t.minute.toString().padLeft(2, '0')}:'
            '${t.second.toString().padLeft(2, '0')}';

    Widget seg(int i) => Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: i == level ? Colors.white : Colors.black26,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              levelLabel(i).toUpperCase(),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: i == level ? levelColor(level) : Colors.white70,
              ),
            ),
          ),
        );

    return Positioned.fill(
      child: Container(
        color: levelColor(level),
        padding: const EdgeInsets.all(20),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 72, color: Colors.white),
                  const SizedBox(height: 8),
                  const Text('GETARAN TERDETEKSI',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: Colors.white)),
                  const SizedBox(height: 4),
                  Text(levelLabel(level).toUpperCase(),
                      style: const TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.w900,
                          color: Colors.white)),
                  Text('${_alarmPeak.toStringAsFixed(2)} m/s²',
                      style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white)),
                  const SizedBox(height: 4),
                  Text(
                      'Batas deteksi ${_threshold.toStringAsFixed(1)} m/s² • $hms',
                      style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 16),
                  Row(children: [seg(0), seg(1), seg(2)]),
                  if (level == 2) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '🚨 PERINGATAN DARURAT\n'
                        'Segera lindungi diri dan cari tempat aman!',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            color: Colors.red.shade900),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                    'Kategori menunjukkan kekuatan getaran HP ini, '
                    'bukan magnitudo gempa.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 96,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: levelColor(level),
                      ),
                      onPressed: _stopAlarm,
                      child: const Text('MATIKAN ALARM',
                          style: TextStyle(
                              fontSize: 26, fontWeight: FontWeight.w900)),
                    ),
                  ),
                ],
              ),
            ),
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

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wifi_scan/wifi_scan.dart';

void main() => runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: Home()));

// ---------- 데이터 ----------
class Sample { final double x, y; final int rssi; final DateTime t;
  Sample(this.x, this.y, this.rssi, this.t); }

class Dev {
  final String id, src; String name, kind;
  final List<Sample> s = [];
  Dev(this.id, this.name, this.kind, this.src);
  double ex = 0, ey = 0, score = 0, persist = 0, corr = 0; int peak = -100, seatR = -1, seatC = -1;
}

// ---------- 분류 ----------
String classify(String name, Map<int, List<int>> mfr, List<String> uuids) {
  final n = name.toLowerCase();
  if (RegExp(r'buds|airpod|pods|earbud|ear|headset|tws|neckloop|loop').hasMatch(n)) return '이어폰';
  if (RegExp(r'glass|ray-ban|meta|xreal|rokid|frame').hasMatch(n)) return '스마트안경';
  if (RegExp(r'watch|band|fit|garmin|amazfit').hasMatch(n)) return '워치';
  if (RegExp(r'iphone|galaxy|pixel|phone|sm-').hasMatch(n)) return '휴대폰';
  final a = mfr[0x004C];
  if (a != null && a.isNotEmpty) {
    if (a[0] == 0x07) return '이어폰(Apple)';
    if (a[0] == 0x10 || a[0] == 0x0C) return '휴대폰(Apple)';
    return 'Apple 기기';
  }
  if (uuids.any((u) => u.toLowerCase().contains('fe2c'))) return '이어폰(FastPair)';
  if (mfr.containsKey(0x0075)) return 'Samsung 기기';
  return '미확인';
}
double kindWeight(String k) => k.contains('이어폰') || k.contains('안경') ? 1.0
    : k.contains('휴대폰') || k.contains('핫스팟') ? 0.9 : k.contains('워치') ? 0.7 : 0.4;

class Home extends StatefulWidget { const Home({super.key}); @override State<Home> createState() => _H(); }

class _H extends State<Home> {
  // 교실 설정 (원점 = 교탁 쪽 왼쪽 앞 모서리, 시작 시 폰을 교실 뒤쪽 방향으로)
  int rows = 5, cols = 6; double gapX = 1.0, gapY = 1.1, stepLen = 0.65;
  // 위치 추적
  double px = 0, py = 0, heading = 0; final path = <Offset>[];
  DateTime lastStep = DateTime(0); double lastMag = 9.8;
  // 상태
  final devs = <String, Dev>{}; final baseline = <String>{};
  bool running = false, baselining = false;
  final subs = <StreamSubscription>[]; Timer? wifiT, anaT;

  Future<void> _perm() async => [Permission.bluetoothScan, Permission.bluetoothConnect,
      Permission.locationWhenInUse, Permission.sensors].request();

  // 걸음 + 방향 (PDR)
  void _startPdr() {
    subs.add(gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval).listen((g) {
      heading -= g.z * 0.02; // 20ms 적분, 시작 방향 = 0
    }));
    subs.add(accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen((a) {
      final m = sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
      final now = DateTime.now();
      if (lastMag < 11.2 && m >= 11.2 && now.difference(lastStep).inMilliseconds > 300) {
        lastStep = now;
        px += stepLen * sin(heading); py += stepLen * cos(heading);
        path.add(Offset(px, py)); if (path.length > 600) path.removeAt(0);
        setState(() {});
      }
      lastMag = m;
    }));
  }

  void _add(String id, String name, String kind, String src, int rssi) {
    if (baselining) { baseline.add(id); return; }
    if (baseline.contains(id)) return;
    final d = devs.putIfAbsent(id, () => Dev(id, name, kind, src));
    if (name.isNotEmpty) d.name = name;
    d.s.add(Sample(px, py, rssi, DateTime.now()));
    if (d.s.length > 400) d.s.removeAt(0);
    if (rssi > d.peak) d.peak = rssi;
  }

  Future<void> _startRadio() async {
    subs.add(FlutterBluePlus.onScanResults.listen((rs) {
      for (final r in rs) {
        final ad = r.advertisementData;
        final name = ad.advName.isNotEmpty ? ad.advName : r.device.platformName;
        _add(r.device.remoteId.str, name, classify(name, ad.manufacturerData,
            ad.serviceUuids.map((e) => e.str).toList()), 'BLE', r.rssi);
      }
    }));
    await FlutterBluePlus.startScan(continuousUpdates: true, androidScanMode: AndroidScanMode.lowLatency);
    if (Platform.isAndroid) {
      wifiT = Timer.periodic(const Duration(seconds: 4), (_) async {
        if (await WiFiScan.instance.canStartScan() != CanStartScan.yes) return;
        await WiFiScan.instance.startScan();
        for (final ap in await WiFiScan.instance.getScannedResults()) {
          final hs = ap.ssid.isEmpty || RegExp(r'iphone|galaxy|android|phone|hotspot|direct-')
              .hasMatch(ap.ssid.toLowerCase());
          _add(ap.bssid, ap.ssid, hs ? '핫스팟 의심' : 'AP', 'WiFi', ap.level);
        }
      });
    }
  }

  // ---------- 패턴 분석 ----------
  void _analyze() {
    final now = DateTime.now();
    for (final d in devs.values) {
      if (d.s.length < 5) continue;
      // 1) 위치 추정: 신호가 강한 샘플일수록 가중 (선형 전력)
      double w = 0, sx = 0, sy = 0;
      for (final s in d.s) { final k = pow(10, s.rssi / 10).toDouble(); w += k; sx += s.x * k; sy += s.y * k; }
      d.ex = sx / w; d.ey = sy / w;
      d.seatC = (d.ex / gapX - 0.5).round().clamp(0, cols - 1);
      d.seatR = (d.ey / gapY - 0.5).round().clamp(0, rows - 1);
      // 2) 지속성: 최근 3분을 10초 구간으로 나눠 감지된 구간 비율
      final bins = <int>{};
      for (final s in d.s) { final a = now.difference(s.t).inSeconds; if (a < 180) bins.add(a ~/ 10); }
      d.persist = bins.length / 18;
      // 3) 거리-세기 일치도: 추정 위치에 가까울수록 세지면 음의 상관 → 한 자리에 고정된 기기
      final xs = d.s.map((s) => log(max(0.3, sqrt(pow(s.x - d.ex, 2) + pow(s.y - d.ey, 2))))).toList();
      final ys = d.s.map((s) => s.rssi.toDouble()).toList();
      final mx = xs.reduce((a, b) => a + b) / xs.length, my = ys.reduce((a, b) => a + b) / ys.length;
      double cov = 0, vx = 0, vy = 0;
      for (int i = 0; i < xs.length; i++) { cov += (xs[i] - mx) * (ys[i] - my); vx += pow(xs[i] - mx, 2); vy += pow(ys[i] - my, 2); }
      d.corr = (vx * vy) > 0 ? cov / sqrt(vx * vy) : 0;
      // 4) 종합 점수 (0~100)
      final peakS = ((d.peak + 85) / 35).clamp(0.0, 1.0);
      final locS = (-d.corr).clamp(0.0, 1.0);
      d.score = 100 * kindWeight(d.kind) * (0.35 * peakS + 0.35 * locS + 0.3 * d.persist.clamp(0.0, 1.0));
    }
    setState(() {});
  }

  Future<void> _baseline() async {
    await _perm(); baselining = true; await _startRadio();
    await Future.delayed(const Duration(seconds: 15));
    FlutterBluePlus.stopScan(); for (final s in subs) { s.cancel(); } subs.clear(); wifiT?.cancel();
    setState(() => baselining = false);
  }

  Future<void> _start() async {
    await _perm();
    px = py = heading = 0; path..clear()..add(Offset.zero); devs.clear();
    _startPdr(); await _startRadio();
    anaT = Timer.periodic(const Duration(seconds: 2), (_) => _analyze());
    setState(() => running = true);
  }

  void _stop() {
    FlutterBluePlus.stopScan(); for (final s in subs) { s.cancel(); } subs.clear();
    wifiT?.cancel(); anaT?.cancel(); setState(() => running = false);
  }

  String seatName(int r, int c) => '${String.fromCharCode(65 + r)}-${c + 1}';

  @override
  Widget build(BuildContext context) {
    final ranked = devs.values.where((d) => d.s.length >= 5).toList()..sort((a, b) => b.score.compareTo(a.score));
    final alerts = ranked.where((d) => d.score >= 60).toList();
    final near = ranked.where((d) => d.s.isNotEmpty &&
        DateTime.now().difference(d.s.last.t).inSeconds < 3 && d.s.last.rssi >= -58 && kindWeight(d.kind) >= 0.9).toList();
    final color = !running ? Colors.blueGrey : alerts.isNotEmpty ? Colors.red : near.isNotEmpty ? Colors.orange : Colors.green;
    final msg = baselining ? '기준 등록 중… 15초 (빈 교실에서)'
        : !running ? '책상 배치 확인 → 원점에 서서 [시작]'
        : alerts.isNotEmpty ? '확인 필요: ${alerts.take(3).map((d) => '${seatName(d.seatR, d.seatC)} ${d.score.round()}%').join(', ')}'
        : near.isNotEmpty ? '근처에 의심 신호 — 천천히 지나가 주세요' : '스캔 중 · 이상 없음';
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      body: SafeArea(child: Column(children: [
        Container(width: double.infinity, margin: const EdgeInsets.all(10), padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
          child: Text(msg, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
        if (!running) Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Row(children: [
          _step('행', rows, (v) => rows = v), _step('열', cols, (v) => cols = v),
          Expanded(child: Text('간격 ${gapX}m × ${gapY}m', textAlign: TextAlign.center)),
        ])),
        Expanded(flex: 5, child: Card(margin: const EdgeInsets.all(10), child: Padding(padding: const EdgeInsets.all(8),
          child: CustomPaint(size: Size.infinite, painter: MapPainter(rows, cols, gapX, gapY, Offset(px, py), path,
              ranked.where((d) => d.score >= 40).toList()))))),
        Expanded(flex: 3, child: ListView(padding: const EdgeInsets.symmetric(horizontal: 10), children: ranked.take(15).map((d) => Card(
          color: d.score >= 60 ? Colors.red.shade50 : null,
          child: ListTile(dense: true,
            leading: CircleAvatar(backgroundColor: d.score >= 60 ? Colors.red : Colors.grey.shade400,
                child: Text('${d.score.round()}', style: const TextStyle(color: Colors.white, fontSize: 12))),
            title: Text('${seatName(d.seatR, d.seatC)} · ${d.kind}'),
            subtitle: Text('최대 ${d.peak}dBm · 지속 ${(d.persist * 100).round()}% · 위치일치 ${(-d.corr * 100).round()}% · ${d.src}'),
          ))).toList())),
        Padding(padding: const EdgeInsets.all(10), child: Row(children: [
          if (!running) Expanded(child: OutlinedButton(onPressed: baselining ? null : _baseline,
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56)), child: Text('기준 등록 (${baseline.length})'))),
          if (!running) const SizedBox(width: 10),
          Expanded(flex: 2, child: FilledButton(onPressed: baselining ? null : (running ? _stop : _start),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 56), backgroundColor: running ? Colors.red : Colors.blue),
              child: Text(running ? '중지' : '원점에서 시작', style: const TextStyle(fontSize: 18)))),
        ])),
      ])),
    );
  }

  Widget _step(String l, int v, void Function(int) set) => Row(children: [
    Text(l), IconButton(icon: const Icon(Icons.remove), onPressed: () => setState(() => set(max(1, v - 1)))),
    Text('$v'), IconButton(icon: const Icon(Icons.add), onPressed: () => setState(() => set(v + 1)))]);
}

// ---------- 맵 (책상 · 감독관 경로 · 의심 기기 히트맵) ----------
class MapPainter extends CustomPainter {
  final int rows, cols; final double gx, gy; final Offset me; final List<Offset> path; final List<Dev> sus;
  MapPainter(this.rows, this.cols, this.gx, this.gy, this.me, this.path, this.sus);
  @override
  void paint(Canvas c, Size s) {
    final w = cols * gx + 0.6, h = rows * gy + 0.6;
    final k = min(s.width / w, s.height / h);
    Offset P(double x, double y) => Offset((x + 0.3) * k, (y + 0.3) * k);
    final desk = Paint()..color = const Color(0xFFCBD5E1);
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (int r = 0; r < rows; r++) for (int cc = 0; cc < cols; cc++) {
      final ctr = P((cc + 0.5) * gx, (r + 0.5) * gy);
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: ctr, width: gx * k * 0.6, height: gy * k * 0.45), const Radius.circular(4)), desk);
      tp.text = TextSpan(text: '${String.fromCharCode(65 + r)}-${cc + 1}', style: const TextStyle(fontSize: 9, color: Colors.black54));
      tp.layout(); tp.paint(c, ctr - Offset(tp.width / 2, tp.height / 2));
    }
    for (final d in sus) {
      final ctr = P(d.ex, d.ey); final col = d.score >= 60 ? Colors.red : Colors.orange;
      c.drawCircle(ctr, gx * k * 0.9, Paint()..shader = RadialGradient(colors: [col.withOpacity(.7), col.withOpacity(0)])
          .createShader(Rect.fromCircle(center: ctr, radius: gx * k * 0.9)));
    }
    if (path.length > 1) {
      final pp = Path()..moveTo(P(path.first.dx, path.first.dy).dx, P(path.first.dx, path.first.dy).dy);
      for (final o in path) { final q = P(o.dx, o.dy); pp.lineTo(q.dx, q.dy); }
      c.drawPath(pp, Paint()..color = Colors.cyan..style = PaintingStyle.stroke..strokeWidth = 2);
    }
    c.drawCircle(P(0, 0), 5, Paint()..color = Colors.teal);
    c.drawCircle(P(me.dx, me.dy), 8, Paint()..color = Colors.blue);
  }
  @override bool shouldRepaint(covariant CustomPainter o) => true;
}

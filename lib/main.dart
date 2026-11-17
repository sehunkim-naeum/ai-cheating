// ExamGuard — 시험장 무선기기 탐지 보조 앱 (MIT License)
// 감독관 휴대폰 한 대로 BLE·Wi-Fi 신호를 수집하고, 걸음 추적 위치와 합쳐
// 숨긴 이어폰·안경·폰이 있을 가능성이 높은 자리를 알려 줍니다.
// 결과는 "확인할 자리"를 알려 주는 참고값이며, 부정행위의 증거가 아닙니다.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wifi_scan/wifi_scan.dart';

void main() => runApp(const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ExamGuard',
      home: Home(),
    ));

// ============================================================
// 데이터
// ============================================================

/// 한 번의 수신 기록: 감독관 위치(x, y, m)와 그때의 신호 세기
class Sample {
  final double x, y;
  final int rssi;
  final DateTime t;
  Sample(this.x, this.y, this.rssi, this.t);
}

/// 감지된 기기 하나 (주소가 바뀌어도 같은 기기로 합쳐서 관리)
class Dev {
  final String id, src;
  String name, kind, fp;
  bool base; // 기준 등록 때 잡힌 상시 기기(감독관 폰, 공유기 등) → 분석 제외
  final Set<String> aliases = {}; // 병합된 이전/이후 주소들
  final List<Sample> s = [];
  double ex = 0, ey = 0, score = 0, persist = 0, corr = 0, repeat = 0;
  int peak = -100, seatR = 0, seatC = 0, range = 0, episodes = 0;
  bool ambiguous = false; // 한쪽 통로에서만 잡혀 좌/우 자리 구분이 안 됨
  bool far = false; // 한 번도 근거리 세기까지 올라오지 않음 → 교실 밖/먼 기기로 보고 제외
  Dev(this.id, this.name, this.kind, this.src, this.fp, this.base);
  DateTime get last => s.isEmpty ? DateTime(0) : s.last.t;
}

// ============================================================
// 기기 분류와 지문
// ============================================================

String classify(String name, Map<int, List<int>> mfr, List<String> uuids) {
  final n = name.toLowerCase();
  if (RegExp(r'buds|airpod|pods|earbud|earphone|headset|tws|neckloop|loop').hasMatch(n)) return '이어폰';
  if (RegExp(r'glass|ray-ban|xreal|rokid|frame').hasMatch(n)) return '스마트안경';
  if (RegExp(r'watch|band|fit|garmin|amazfit').hasMatch(n)) return '워치';
  if (RegExp(r'iphone|galaxy|pixel|phone|sm-').hasMatch(n)) return '휴대폰';
  final a = mfr[0x004C]; // Apple Continuity
  if (a != null && a.isNotEmpty) {
    if (a[0] == 0x07) return '이어폰(Apple)';
    if (a[0] == 0x10 || a[0] == 0x0C) return '휴대폰(Apple)';
    return 'Apple 기기';
  }
  if (uuids.any((u) => u.toLowerCase().contains('fe2c'))) return '이어폰(FastPair)';
  if (mfr.containsKey(0x0075)) return 'Samsung 기기';
  if (mfr.containsKey(0x00E0)) return 'Google 기기';
  return '미확인';
}

double kindWeight(String k) {
  if (k.contains('이어폰') || k.contains('안경')) return 1.0;
  if (k.contains('휴대폰') || k.contains('핫스팟')) return 0.9;
  if (k.contains('워치')) return 0.7;
  return 0.4;
}

/// 주소가 바뀌어도 잘 변하지 않는 광고 패킷 특징(제조사 코드·데이터 길이·타입, 서비스 UUID, 송신 세기)
String fingerprint(Map<int, List<int>> mfr, List<String> uuids, int? tx) {
  final parts = <String>[];
  mfr.forEach((k, v) => parts.add('$k:${v.length}:${v.isNotEmpty ? v[0] : -1}'));
  parts.addAll(uuids.map((u) => u.toLowerCase()));
  if (parts.isEmpty) return '';
  parts.sort();
  return '${parts.join('|')}#${tx ?? 0}';
}

// ============================================================
// 화면 (한 페이지)
// ============================================================

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

enum Mode { setup, baseline, patrol, entry }

class _HomeState extends State<Home> {
  // ---------- 교실 설정 (원점 = 교탁 쪽 왼쪽 앞 모서리, 시작할 때 폰을 교실 뒤쪽으로 향함) ----------
  int rows = 5, cols = 6;
  double gapX = 1.0, gapY = 1.1; // 책상 중심 간격(m)
  double stepLen = 0.65; // 보폭(m) — [보폭 보정]으로 자동 계산
  int alertScore = 60; // 경고 점수 기준 — 현장에 맞게 조절
  int nearRssi = -65; // 근거리 기준(dBm): 순찰 중 한 번도 이보다 세게 잡히지 않은 기기는 먼 기기로 제외
  final disabled = <int>{}; // 수동 매핑: 감독관이 끈 자리(빈자리·없는 책상), 인덱스 = 행×열수 + 열
  final roomCtl = TextEditingController(text: '제1고사장'); // 고사장 이름 (맵·결과에 표시)

  Mode mode = Mode.setup;
  String toast = '';
  Timer? toastT;

  // ---------- 위치 추적 (PDR + 통로 맵 매칭) ----------
  double px = 0, py = 0, heading = 0;
  final path = <Offset>[];
  double gX = 0, gY = 0, gZ = 9.8; // 저역통과로 구한 중력 방향
  DateTime? lastGyro;
  final accWin = <double>[]; // 최근 약 1초 가속도 크기 (적응형 걸음 감지)
  double lastMag = 9.8;
  DateTime lastStep = DateTime(0);
  int steps = 0, reanchors = 0;
  final turnWin = <MapEntry<DateTime, double>>[]; // 최근 회전량 (U턴 감지)
  DateTime lastUTurn = DateTime(0);
  bool calibrating = false;
  int calSteps = 0;

  // ---------- 신호 ----------
  final devs = <String, Dev>{};
  final alias = <String, String>{}; // 바뀐 주소 → 원래 기기 id
  int merges = 0;
  final subs = <StreamSubscription>[];
  Timer? wifiT, anaT;

  // ---------- 입실 점검 (자기장) ----------
  double magBase = 0, magNow = 0;
  final magCal = <double>[];

  double get maxX => cols * gapX;
  double get maxY => rows * gapY;

  void _toast(String m) {
    toastT?.cancel();
    setState(() => toast = m);
    toastT = Timer(const Duration(seconds: 3), () => setState(() => toast = ''));
  }

  Future<void> _perm() async {
    if (Platform.isAndroid) {
      await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
    }
    // iOS는 flutter_blue_plus가 첫 스캔 때 블루투스 권한을 직접 요청합니다.
    try {
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      _toast('블루투스를 켜 주세요');
    }
  }

  void _stopAll() {
    FlutterBluePlus.stopScan();
    for (final s in subs) {
      s.cancel();
    }
    subs.clear();
    wifiT?.cancel();
    anaT?.cancel();
  }

  // ============================================================
  // 위치 추적
  // ============================================================

  void _startPdr() {
    // 가속도: 중력 방향 추정 + 적응형 걸음 감지
    subs.add(accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen((a) {
      gX = 0.9 * gX + 0.1 * a.x;
      gY = 0.9 * gY + 0.1 * a.y;
      gZ = 0.9 * gZ + 0.1 * a.z;
      final m = sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
      accWin.add(m);
      if (accWin.length > 50) accWin.removeAt(0);
      final mean = accWin.reduce((p, q) => p + q) / accWin.length;
      final sd = sqrt(accWin.map((v) => (v - mean) * (v - mean)).reduce((p, q) => p + q) / accWin.length);
      // 기준값을 고정(11.2)하지 않고 최근 흔들림에 맞춰 자동 조정: 평균 + max(0.6, 0.8·표준편차)
      final thr = mean + max(0.6, 0.8 * sd);
      final now = DateTime.now();
      if (lastMag < thr && m >= thr && m - mean > 1.0 && now.difference(lastStep).inMilliseconds > 300) {
        lastStep = now;
        steps++;
        if (calibrating) calSteps++;
        _onStep();
      }
      lastMag = m;
    }));

    // 자이로: 폰을 어떻게 들어도 '중력축 기준 회전'만 쓰므로 방향이 정확
    subs.add(gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval).listen((w) {
      final now = DateTime.now();
      final dt = lastGyro == null ? 0.0 : now.difference(lastGyro!).inMicroseconds / 1e6;
      lastGyro = now;
      final gn = sqrt(gX * gX + gY * gY + gZ * gZ);
      if (dt <= 0 || dt > 0.2 || gn < 1) return;
      final yaw = (w.x * gX + w.y * gY + w.z * gZ) / gn; // 반시계 +
      heading -= yaw * dt; // heading: 교실 뒤쪽 = 0, 오른쪽으로 돌면 +

      // 방향 보정: 똑바로 걷는 중이면 가장 가까운 교실 축(0/90/180/270°)으로 천천히 당겨 자이로 드리프트 제거
      if (yaw.abs() < 0.3) {
        final snap = (heading / (pi / 2)).round() * (pi / 2);
        heading += (snap - heading) * 0.01;
      }

      // U턴 감지: 최근 5초 회전이 150° 이상이면 통로 끝에서 돌아선 것으로 보고 위치 재보정
      turnWin.add(MapEntry(now, -yaw * dt));
      turnWin.removeWhere((e) => now.difference(e.key).inMilliseconds > 5000);
      final turned = turnWin.fold<double>(0, (p, e) => p + e.value);
      if (turned.abs() > 150 * pi / 180 && now.difference(lastUTurn).inSeconds > 3) {
        lastUTurn = now;
        turnWin.clear();
        _onUTurn();
      }
    }));
  }

  /// 통로 스냅: 배치도를 알고 있고 감독관은 통로로만 다닌다는 가정으로 위치 보정
  /// 세로 통로 x = 0, gapX, …, cols·gapX / 앞·뒤 가로 통로 y = 0, rows·gapY
  void _onStep() {
    final mx = stepLen * sin(heading), my = stepLen * cos(heading);
    if (my.abs() >= mx.abs()) {
      px = ((px / gapX).round() * gapX).clamp(0.0, maxX).toDouble();
      py = (py + my).clamp(0.0, maxY).toDouble();
    } else {
      px = (px + mx).clamp(0.0, maxX).toDouble();
      py = py < maxY / 2 ? 0.0 : maxY;
    }
    path.add(Offset(px, py));
    if (path.length > 800) path.removeAt(0);
    setState(() {});
  }

  /// U턴 자동 재보정: 통로 끝 근처(양 끝 30% 이내)에서 돌아섰다면 위치를 그 끝으로 맞춤
  void _onUTurn() {
    if ((py - 0).abs() < 0.3 * maxY) {
      py = 0;
    } else if ((maxY - py).abs() < 0.3 * maxY) {
      py = maxY;
    } else {
      return; // 통로 중간에서 돌아선 경우는 건드리지 않음
    }
    px = ((px / gapX).round() * gapX).clamp(0.0, maxX).toDouble();
    reanchors++;
    _toast('통로 끝 U턴 감지 → 위치 자동 재보정');
  }

  /// 탭 보정: 맵에서 감독관이 실제 서 있는 곳을 탭하면 그 지점으로 위치 재설정
  void _anchor(Offset local, Size size) {
    final k = min(size.width / (maxX + 0.6), size.height / (maxY + 0.6));
    setState(() {
      px = (local.dx / k - 0.3).clamp(0.0, maxX).toDouble();
      py = (local.dy / k - 0.3).clamp(0.0, maxY).toDouble();
      path.add(Offset(px, py));
      reanchors++;
    });
    _toast('탭한 위치로 재보정');
  }

  /// 보폭 보정: 원점에서 첫 통로를 따라 교실 맨 뒤까지 걸은 뒤 [도착]을 누르면 보폭 자동 계산
  void _finishCalibration() {
    if (calSteps >= 4) {
      stepLen = (maxY / calSteps).clamp(0.4, 1.0).toDouble();
      _toast('보폭 ${stepLen.toStringAsFixed(2)}m로 보정 (${calSteps}걸음)');
    } else {
      _toast('걸음이 너무 적어요. 다시 시도해 주세요');
    }
    calibrating = false;
    px = 0;
    py = maxY; // 첫 통로 맨 뒤에 도착한 상태로 맞춤
    path.add(Offset(px, py));
    setState(() {});
  }

  // ============================================================
  // 신호 수집
  // ============================================================

  /// 주소가 바뀐 같은 기기 찾기 (iOS·Android의 BLE 주소 랜덤화 보완)
  /// 같은 지문·같은 종류이고, 이전 주소가 끊긴 지 2~30초 안에 비슷한 세기로 새 주소가 나타나면 같은 기기로 병합
  Dev? _resolve(String id, String fp, String kind, int rssi) {
    final a = alias[id];
    if (a != null) return devs[a];
    final d0 = devs[id];
    if (d0 != null) return d0;
    if (fp.isEmpty) return null;
    final now = DateTime.now();
    for (final d in devs.values) {
      if (d.src != 'BLE' || d.fp != fp || d.kind != kind || d.s.isEmpty) continue;
      final gap = now.difference(d.last).inSeconds;
      if (gap >= 2 && gap <= 30 && (d.s.last.rssi - rssi).abs() <= 10) {
        alias[id] = d.id;
        d.aliases.add(id);
        if (!d.base) {
          merges++;
          _toast('주소가 바뀐 기기를 같은 기기로 병합');
        }
        return d;
      }
    }
    return null;
  }

  void _add(String id, String name, String kind, String src, String fp, int rssi) {
    final isBase = mode == Mode.baseline;
    var d = src == 'BLE' ? _resolve(id, fp, kind, rssi) : devs[id];
    d ??= devs[id] = Dev(id, name, kind, src, fp, isBase);
    if (name.isNotEmpty) d.name = name;
    d.s.add(Sample(px, py, rssi, DateTime.now()));
    if (d.s.length > 500) d.s.removeAt(0);
    if (rssi > d.peak) d.peak = rssi;
  }

  Future<void> _startRadio() async {
    subs.add(FlutterBluePlus.onScanResults.listen((rs) {
      for (final r in rs) {
        final ad = r.advertisementData;
        final name = ad.advName.isNotEmpty ? ad.advName : r.device.platformName;
        final uuids = ad.serviceUuids.map((e) => e.str).toList();
        _add(r.device.remoteId.str, name, classify(name, ad.manufacturerData, uuids), 'BLE',
            fingerprint(ad.manufacturerData, uuids, ad.txPowerLevel), r.rssi);
      }
    }));
    await FlutterBluePlus.startScan(continuousUpdates: true, androidScanMode: AndroidScanMode.lowLatency);

    // Wi-Fi(Android만): 안드로이드는 앱당 2분에 4번만 스캔을 허용하므로 30초 간격
    if (Platform.isAndroid) {
      Future<void> scan() async {
        if (await WiFiScan.instance.canStartScan() != CanStartScan.yes) return;
        await WiFiScan.instance.startScan();
        for (final ap in await WiFiScan.instance.getScannedResults()) {
          final hs = ap.ssid.isEmpty ||
              RegExp(r'iphone|galaxy|android|phone|hotspot|direct-').hasMatch(ap.ssid.toLowerCase());
          _add(ap.bssid, ap.ssid, hs ? '핫스팟 의심' : 'AP', 'WiFi', '', ap.level);
        }
      }

      scan();
      wifiT = Timer.periodic(const Duration(seconds: 30), (_) => scan());
    }
  }

  // ============================================================
  // 패턴 분석
  // ============================================================

  void _analyze() {
    final now = DateTime.now();
    for (final d in devs.values) {
      if (d.base || d.s.length < 5) continue;
      // 0) 원거리 제외: 감독관이 모든 통로를 지나가면 교실 안 기기는 1m 안쪽으로 한 번은 지나가므로
      //    근거리 기준보다 세게 잡힌 적이 없는 기기는 옆 교실·복도 등 먼 기기로 판단
      d.far = d.peak < nearRssi;
      if (d.far) {
        d.score = 0;
        continue;
      }
      // 1) 위치 추정: 강하게 잡힌 지점일수록 가중(선형 전력)
      double w = 0, sx = 0, sy = 0;
      for (final s in d.s) {
        final k = pow(10, s.rssi / 10).toDouble();
        w += k;
        sx += s.x * k;
        sy += s.y * k;
      }
      d.ex = sx / w;
      d.ey = sy / w;
      // 감독관이 켜 둔 자리 중 가장 가까운 자리에 배정 (수동 매핑 반영)
      double best = double.infinity;
      for (int r = 0; r < rows; r++) {
        for (int c = 0; c < cols; c++) {
          if (disabled.contains(r * cols + c)) continue;
          final dd = pow((c + 0.5) * gapX - d.ex, 2) + pow((r + 0.5) * gapY - d.ey, 2);
          if (dd < best) {
            best = dd.toDouble();
            d.seatR = r;
            d.seatC = c;
          }
        }
      }
      // 한쪽 통로에서만 강하게 잡혔으면 좌/우 자리 구분 불가 → 두 자리 모두 표시
      final strongAisles =
          d.s.where((s) => s.rssi >= d.peak - 8).map((s) => (s.x / gapX).round()).toSet();
      d.ambiguous = strongAisles.length < 2;

      // 2) 지속성: 최근 3분을 10초 구간 18개로 나눠 감지된 구간 비율
      final bins = <int>{};
      for (final s in d.s) {
        final a = now.difference(s.t).inSeconds;
        if (a < 180) bins.add(a ~/ 10);
      }
      d.persist = bins.length / 18;

      // 3) 거리-세기 일치도: 추정 위치에 가까울수록 세지면(음의 상관) 한 자리에 고정된 기기
      final xs = d.s.map((s) => log(max(0.3, sqrt(pow(s.x - d.ex, 2) + pow(s.y - d.ey, 2))))).toList();
      final ys = d.s.map((s) => s.rssi.toDouble()).toList();
      final mx = xs.reduce((a, b) => a + b) / xs.length, my = ys.reduce((a, b) => a + b) / ys.length;
      double cov = 0, vx = 0, vy = 0;
      for (int i = 0; i < xs.length; i++) {
        cov += (xs[i] - mx) * (ys[i] - my);
        vx += pow(xs[i] - mx, 2);
        vy += pow(ys[i] - my, 2);
      }
      d.corr = (vx * vy) > 0 ? cov / sqrt(vx * vy) : 0;

      // 4) 세기 변화폭: 최대 − 하위 20% 세기. 가까운 기기는 감독관이 멀어지면 크게 약해지고(15dB↑),
      //    먼 기기·벽 너머 공유기는 어디서 재도 비슷해 변화폭이 작음
      final sorted = ys.toList()..sort();
      d.range = d.peak - sorted[(sorted.length * 0.2).floor()].round();

      // 5) 반복 피크 패턴: 감독관이 지나갈 때마다 세기가 확 올라갔다 내려가는 '근접 통과'를 구간으로 나누고,
      //    각 구간의 최고점 위치가 같은 자리(1m 이내)에 모이는지 확인 → 여러 바퀴에서 같은 곳이면 고정된 기기
      final peaksAt = <Offset>[];
      Sample? cur;
      DateTime? lastHigh;
      for (final s in d.s) {
        if (s.rssi < d.peak - 6) continue;
        if (lastHigh != null && s.t.difference(lastHigh).inSeconds > 5 && cur != null) {
          peaksAt.add(Offset(cur.x, cur.y));
          cur = null;
        }
        if (cur == null || s.rssi > cur.rssi) cur = s;
        lastHigh = s.t;
      }
      if (cur != null) peaksAt.add(Offset(cur.x, cur.y));
      d.episodes = peaksAt.length;
      final consistent =
          peaksAt.where((o) => sqrt(pow(o.dx - d.ex, 2) + pow(o.dy - d.ey, 2)) <= 1.0).length;
      d.repeat = peaksAt.isEmpty ? 0 : (min(d.episodes, 3) / 3) * (consistent / peaksAt.length);

      // 6) 종합 점수(0~100) = 종류 가중치 × (근접 피크 25% + 위치 일치 25% + 변화폭 20% + 반복 피크 15% + 지속성 15%)
      final peakS = ((d.peak - nearRssi) / (nearRssi.abs() - 40)).clamp(0.0, 1.0); // 근거리 기준~−40dBm
      final locS = (-d.corr).clamp(0.0, 1.0);
      final rangeS = ((d.range - 5) / 15).clamp(0.0, 1.0); // 5dB 이하 0점, 20dB 이상 만점
      d.score = 100 *
          kindWeight(d.kind) *
          (0.25 * peakS + 0.25 * locS + 0.2 * rangeS + 0.15 * d.repeat + 0.15 * d.persist.clamp(0.0, 1.0));
    }
    setState(() {});
  }

  // ============================================================
  // 모드 전환
  // ============================================================

  Future<void> _baseline() async {
    await _perm();
    setState(() => mode = Mode.baseline);
    await _startRadio();
    await Future.delayed(const Duration(seconds: 15));
    _stopAll();
    setState(() => mode = Mode.setup);
    _toast('상시 기기 ${devs.values.where((d) => d.base).length}개 등록');
  }

  Future<void> _start({bool calibrate = false}) async {
    await _perm();
    px = py = heading = 0;
    steps = 0;
    path
      ..clear()
      ..add(Offset.zero);
    devs.removeWhere((k, d) => !d.base);
    calibrating = calibrate;
    calSteps = 0;
    _startPdr();
    await _startRadio();
    anaT = Timer.periodic(const Duration(seconds: 2), (_) => _analyze());
    setState(() => mode = Mode.patrol);
    if (calibrate) _toast('첫 통로를 따라 교실 맨 뒤까지 걸은 뒤 [도착]을 누르세요');
  }

  /// 입실 점검: 전원이 꺼진 폰·이어폰도 스피커 자석과 금속이 있어 2~10cm 안에서 자기장이 튐
  void _entry() {
    _stopAll();
    magCal.clear();
    setState(() {
      mode = Mode.entry;
      magBase = 0;
    });
    subs.add(magnetometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen((m) {
      final b = sqrt(m.x * m.x + m.y * m.y + m.z * m.z);
      if (magCal.length < 30) {
        magCal.add(b); // 처음 0.5~2초는 주변 기준값 측정 (폰을 몸에서 떨어뜨린 채)
        if (magCal.length == 30) magBase = (List<double>.from(magCal)..sort())[15];
      }
      setState(() => magNow = b);
    }));
  }

  void _stop() {
    _stopAll();
    setState(() {
      mode = Mode.setup;
      calibrating = false;
    });
  }

  String seatName(int r, int c) => '${String.fromCharCode(65 + r)}-${c + 1}';
  String seatLabel(Dev d) {
    if (!d.ambiguous) return seatName(d.seatR, d.seatC);
    final a = (d.ex / gapX).round(); // 이 통로 양옆 자리 중 켜져 있는 자리
    final cand = <int>{(a - 1).clamp(0, cols - 1), a.clamp(0, cols - 1)}
        .where((c) => !disabled.contains(d.seatR * cols + c))
        .toList()
      ..sort();
    if (cand.length < 2) return seatName(d.seatR, d.seatC);
    return '${seatName(d.seatR, cand[0])}/${cand[1] + 1}';
  }

  /// 수동 매핑: 설정 화면에서 맵의 책상을 탭하면 그 자리를 끄고 켬(빈자리·없는 책상 표시)
  void _toggleSeat(Offset local, Size size) {
    final k = min(size.width / (maxX + 0.6), size.height / (maxY + 0.6));
    final x = local.dx / k - 0.3, y = local.dy / k - 0.3;
    final c = (x / gapX).floor(), r = (y / gapY).floor();
    if (r < 0 || r >= rows || c < 0 || c >= cols) return;
    final i = r * cols + c;
    setState(() => disabled.contains(i) ? disabled.remove(i) : disabled.add(i));
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final ranked = devs.values.where((d) => !d.base && d.s.length >= 5).toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    final alerts = ranked.where((d) => d.score >= alertScore).toList();
    final now = DateTime.now();
    final near = ranked
        .where((d) => now.difference(d.last).inSeconds < 3 && d.s.last.rssi >= -58 && kindWeight(d.kind) >= 0.9)
        .toList();
    final magDelta = magBase == 0 ? 0.0 : (magNow - magBase).abs();

    Color color;
    String msg;
    switch (mode) {
      case Mode.setup:
        color = Colors.blueGrey;
        msg = '배치도 입력 → [기준 등록] → [보폭 보정 후 시작]';
      case Mode.baseline:
        color = Colors.indigo;
        msg = '기준 등록 중… 15초 (빈 교실에서)';
      case Mode.entry:
        color = magBase == 0 ? Colors.indigo : (magDelta > 30 ? Colors.red : Colors.green);
        msg = magBase == 0
            ? '기준 측정 중… 폰을 몸에서 떼고 잠시 대기'
            : magDelta > 30
                ? '자기장 이상 +${magDelta.round()}μT — 이 부위 확인'
                : '정상 (${magDelta.round()}μT) — 귀·주머니·안경에 5cm까지 대 보세요';
      case Mode.patrol:
        if (calibrating) {
          color = Colors.indigo;
          msg = '보폭 보정 중 · $calSteps걸음 — 맨 뒤 도착 시 [도착]';
        } else if (alerts.isNotEmpty) {
          color = Colors.red;
          msg = '확인 필요: ${alerts.take(3).map((d) => '${seatLabel(d)} ${d.score.round()}점').join(', ')}';
        } else if (near.isNotEmpty) {
          color = Colors.orange;
          msg = '근처에 의심 신호 — 천천히 지나가 주세요';
        } else {
          color = Colors.green;
          msg = '순찰 중 · 이상 없음';
        }
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      body: SafeArea(
        child: Column(children: [
          // ---- 상태 배너 ----
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(10, 10, 10, 4),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
            child: Text(msg,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          if (toast.isNotEmpty)
            Text(toast, style: const TextStyle(color: Colors.indigo, fontWeight: FontWeight.w600)),

          // ---- 설정 (시작 전에만) ----
          if (mode == Mode.setup)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Column(children: [
                TextField(
                  controller: roomCtl,
                  decoration: const InputDecoration(labelText: '고사장 이름', isDense: true),
                  onChanged: (_) => setState(() {}),
                ),
                Row(children: [
                  _stepper('행', '$rows', () {
                    rows = max(1, rows - 1);
                    disabled.clear();
                  }, () {
                    rows++;
                    disabled.clear();
                  }),
                  _stepper('열', '$cols', () {
                    cols = max(1, cols - 1);
                    disabled.clear();
                  }, () {
                    cols++;
                    disabled.clear();
                  }),
                ]),
                Row(children: [
                  _stepper('좌우 간격', '${gapX.toStringAsFixed(1)}m', () => gapX = max(0.5, gapX - 0.1),
                      () => gapX += 0.1),
                  _stepper('앞뒤 간격', '${gapY.toStringAsFixed(1)}m', () => gapY = max(0.5, gapY - 0.1),
                      () => gapY += 0.1),
                ]),
                Row(children: [
                  Text('경고 기준 $alertScore점'),
                  Expanded(
                    child: Slider(
                        min: 40,
                        max: 90,
                        divisions: 10,
                        value: alertScore.toDouble(),
                        onChanged: (v) => setState(() => alertScore = v.round())),
                  ),
                  Text('보폭 ${stepLen.toStringAsFixed(2)}m'),
                ]),
                Row(children: [
                  Text('근거리 기준 ${nearRssi}dBm'),
                  Expanded(
                    child: Slider(
                        min: -80,
                        max: -50,
                        divisions: 30,
                        value: nearRssi.toDouble(),
                        onChanged: (v) => setState(() => nearRssi = v.round())),
                  ),
                ]),
                Text('책상을 탭하면 빈자리로 표시(다시 탭하면 복구) · 사용 ${rows * cols - disabled.length}석',
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ]),
            ),

          // ---- 맵 또는 입실 점검 게이지 ----
          Expanded(
            flex: 5,
            child: Card(
              margin: const EdgeInsets.all(10),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: mode == Mode.entry
                    ? _magGauge(magDelta)
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(
                            '${roomCtl.text} · ${rows * cols - disabled.length}석 · 신호 히트맵 (교탁 ↑)',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black54)),
                        Expanded(child: LayoutBuilder(
                        builder: (ctx, box) => GestureDetector(
                          onTapUp: mode == Mode.patrol
                              ? (e) => _anchor(e.localPosition, Size(box.maxWidth, box.maxHeight))
                              : mode == Mode.setup
                                  ? (e) => _toggleSeat(e.localPosition, Size(box.maxWidth, box.maxHeight))
                                  : null,
                          child: CustomPaint(
                            size: Size.infinite,
                            painter: MapPainter(rows, cols, gapX, gapY, Offset(px, py), path,
                                ranked.where((d) => d.score >= 40).toList(), alertScore, disabled),
                          ),
                        ),
                      )),
                      ]),
              ),
            ),
          ),
          if (mode == Mode.patrol) ...[
            // 수집 현황: 몇 대가 잡혔고 그중 몇 대를 왜 빼고 몇 대를 분석했는지
            Text(
                '수집 ${devs.values.where((d) => !d.base).length}대 · 기준제외 ${devs.values.where((d) => d.base).length} · '
                '원거리제외 ${devs.values.where((d) => !d.base && d.far).length} · 근거리분석 ${ranked.where((d) => !d.far).length} · '
                '의심 ${alerts.length}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            Text('걸음 $steps · 재보정 $reanchors회 · 주소병합 $merges건 · 맵을 탭하면 위치 보정',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ],

          // ---- 기기 목록 ----
          if (mode != Mode.entry)
            Expanded(
              flex: 3,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: ranked
                    .where((d) => !d.far) // 먼 기기는 목록에서도 숨김
                    .take(15)
                    .map((d) => Card(
                          color: d.score >= alertScore ? Colors.red.shade50 : null,
                          child: ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              backgroundColor: d.score >= alertScore ? Colors.red : Colors.grey.shade400,
                              child: Text('${d.score.round()}',
                                  style: const TextStyle(color: Colors.white, fontSize: 12)),
                            ),
                            title: Text('${seatLabel(d)} · ${d.kind}${d.aliases.isNotEmpty ? ' (주소 ${d.aliases.length + 1}개 병합)' : ''}'),
                            subtitle: Text(
                                '최대 ${d.peak}dBm · 변화폭 ${d.range}dB · 반복피크 ${d.episodes}회 · '
                                '위치일치 ${(-d.corr * 100).clamp(0, 100).round()}% · 지속 ${(d.persist * 100).round()}% · ${d.src}'),
                          ),
                        ))
                    .toList(),
              ),
            ),

          // ---- 하단 버튼 ----
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: _buttons()),
          ),
        ]),
      ),
    );
  }

  List<Widget> _buttons() {
    Widget big(String t, VoidCallback? f, Color c, {int flex = 1}) => Expanded(
          flex: flex,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: FilledButton(
              onPressed: f,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 56), backgroundColor: c),
              child: Text(t, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
            ),
          ),
        );
    switch (mode) {
      case Mode.setup:
        return [
          big('기준 등록\n(${devs.values.where((d) => d.base).length})', _baseline, Colors.indigo),
          big('입실 점검', _entry, Colors.teal),
          big('보폭 보정\n후 시작', () => _start(calibrate: true), Colors.blue, flex: 2),
        ];
      case Mode.baseline:
        return [big('기준 등록 중…', null, Colors.indigo)];
      case Mode.entry:
        return [big('점검 종료', _stop, Colors.red)];
      case Mode.patrol:
        return [
          if (calibrating) big('도착 (맨 뒤)', _finishCalibration, Colors.indigo, flex: 2),
          big('중지', _stop, Colors.red),
        ];
    }
  }

  Widget _stepper(String label, String value, VoidCallback dec, VoidCallback inc) => Expanded(
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(label),
          IconButton(icon: const Icon(Icons.remove), onPressed: () => setState(dec)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
          IconButton(icon: const Icon(Icons.add), onPressed: () => setState(inc)),
        ]),
      );

  Widget _magGauge(double delta) => Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Text('자기장 변화', style: TextStyle(fontSize: 16)),
        Text('${delta.round()} μT',
            style: TextStyle(
                fontSize: 56, fontWeight: FontWeight.bold, color: delta > 30 ? Colors.red : Colors.green)),
        Padding(
          padding: const EdgeInsets.all(16),
          child: LinearProgressIndicator(
              value: (delta / 100).clamp(0.0, 1.0),
              minHeight: 14,
              color: delta > 30 ? Colors.red : Colors.green),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('전원이 꺼진 폰·이어폰도 스피커 자석 때문에 2~10cm 안에서 값이 크게 튑니다. '
              '입실할 때 귀·주머니·안경 주변에 폰을 천천히 대 보세요. 금속 장신구·벨트도 반응하므로 확인용입니다.',
              textAlign: TextAlign.center),
        ),
      ]);

  @override
  void dispose() {
    _stopAll();
    toastT?.cancel();
    super.dispose();
  }
}

// ============================================================
// 맵 (책상 · 통로 · 감독관 경로 · 의심 기기 히트맵)
// ============================================================

class MapPainter extends CustomPainter {
  final int rows, cols, alertScore;
  final double gx, gy;
  final Offset me;
  final List<Offset> path;
  final List<Dev> sus;
  final Set<int> disabled;
  MapPainter(this.rows, this.cols, this.gx, this.gy, this.me, this.path, this.sus, this.alertScore, this.disabled);

  @override
  void paint(Canvas c, Size s) {
    final w = cols * gx + 0.6, h = rows * gy + 0.6;
    final k = min(s.width / w, s.height / h);
    Offset p(double x, double y) => Offset((x + 0.3) * k, (y + 0.3) * k);

    // 통로
    final aisle = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..strokeWidth = 2;
    for (int i = 0; i <= cols; i++) {
      c.drawLine(p(i * gx, 0), p(i * gx, rows * gy), aisle);
    }
    c.drawLine(p(0, 0), p(cols * gx, 0), aisle);
    c.drawLine(p(0, rows * gy), p(cols * gx, rows * gy), aisle);

    // 책상
    final desk = Paint()..color = const Color(0xFFCBD5E1);
    final off = Paint()
      ..color = const Color(0xFFCBD5E1)
      ..style = PaintingStyle.stroke;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (int r = 0; r < rows; r++) {
      for (int cc = 0; cc < cols; cc++) {
        final ctr = p((cc + 0.5) * gx, (r + 0.5) * gy);
        final isOff = disabled.contains(r * cols + cc); // 수동 매핑으로 끈 자리는 테두리만
        c.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromCenter(center: ctr, width: gx * k * 0.6, height: gy * k * 0.45), const Radius.circular(4)),
            isOff ? off : desk);
        tp.text = TextSpan(
            text: isOff ? '빈자리' : '${String.fromCharCode(65 + r)}-${cc + 1}',
            style: const TextStyle(fontSize: 9, color: Colors.black54));
        tp.layout();
        tp.paint(c, ctr - Offset(tp.width / 2, tp.height / 2));
      }
    }

    // 의심 기기 히트맵
    for (final d in sus) {
      final ctr = p(d.ex, d.ey);
      final col = d.score >= alertScore ? Colors.red : Colors.orange;
      final r = gx * k * 0.9;
      c.drawCircle(
          ctr,
          r,
          Paint()
            ..shader = RadialGradient(colors: [col.withOpacity(.7), col.withOpacity(0)])
                .createShader(Rect.fromCircle(center: ctr, radius: r)));
    }

    // 감독관 경로와 현재 위치
    if (path.length > 1) {
      final pp = Path()..moveTo(p(path.first.dx, path.first.dy).dx, p(path.first.dx, path.first.dy).dy);
      for (final o in path) {
        final q = p(o.dx, o.dy);
        pp.lineTo(q.dx, q.dy);
      }
      c.drawPath(
          pp,
          Paint()
            ..color = Colors.cyan
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
    c.drawCircle(p(0, 0), 5, Paint()..color = Colors.teal);
    c.drawCircle(p(me.dx, me.dy), 8, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'mitm_ca.dart';

enum VpnStatus { disconnected, connecting, connected, disconnecting }

class VpnStateEvent {
  final VpnStatus status;
  final String? error;
  final DateTime? connectedAt;

  /// What the Psiphon / Tor exit is doing ("Tor 45% · Loading relay descriptors",
  /// "Psiphon reconnecting…"); null otherwise.
  final String? detail;
  const VpnStateEvent(this.status, this.error, this.connectedAt, this.detail);
}

class InstalledApp {
  final String packageName;
  final String label;
  final bool isSystem;
  final Uint8List? icon;
  const InstalledApp(this.packageName, this.label, this.isSystem, this.icon);
}

/// Bridge to the Android VPN service and Xray core (see MainActivity.kt).
class VpnChannel {
  static const _methods = MethodChannel('bpb/core');
  static const _events = EventChannel('bpb/state');
  static Future<bool>? _supportsAppendHttpProxy;

  static Future<bool> get supportsAppendHttpProxy {
    if (Platform.isWindows || kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(false);
    }
    return _supportsAppendHttpProxy ??= _methods
        .invokeMethod<bool>('supportsAppendHttpProxy')
        .then((supported) => supported ?? false);
  }

  static Stream<VpnStateEvent> get states {
    if (Platform.isWindows) {
      unawaited(_WindowsVpnBackend.recover());
      return _WindowsVpnBackend.states;
    }
    return _events.receiveBroadcastStream().map((e) {
    final map = Map<String, dynamic>.from(e as Map);
    final at = (map['connectedAt'] as num?)?.toInt() ?? 0;
    return VpnStateEvent(
      VpnStatus.values.byName(map['state'] as String),
      map['error'] as String?,
      at > 0 ? DateTime.fromMillisecondsSinceEpoch(at) : null,
      map['detail'] as String?,
    );
  });
  }

  /// Asks for VPN permission if needed; true when granted.
  /// Asks for notification permission and, when [vpn], the VPN permission.
  static Future<bool> prepare({bool vpn = true}) async {
    if (Platform.isWindows) return _WindowsVpnBackend.prepare(vpn: vpn);
    return await _methods.invokeMethod<bool>('prepare', {'vpn': vpn}) ?? false;
  }

static Future<void> start({
    required Map<String, dynamic> config,
    required String remark,
    required String perAppMode,
    required List<String> apps,
    required int mtu,
    bool appendHttpProxy = false,
    bool proxyOnly = false,
    String? exit,
    bool exitDirect = false,
    String exitRegion = '',
    String? torBridge,
    List<String> torCustomBridges = const [],
    Map<String, dynamic>? psiphonConfig,
    bool browserDialer = false,
  }) {
    if (Platform.isWindows) return _WindowsVpnBackend.start(config: config, proxyOnly: proxyOnly, exit: exit, browserDialer: browserDialer);
    return _methods.invokeMethod('start', {
    'config': jsonEncode(config),
    'remark': remark,
    'perAppMode': perAppMode,
    'apps': apps,
    'mtu': mtu,
    'appendHttpProxy': appendHttpProxy,
    'proxyOnly': proxyOnly,
    // Starts that exit process ("psiphon" / "tor"); null for none.
    'exit': exit,
    // The Psiphon / Tor type: the exit connects by itself, not through Xray's psiphon-in / tor-in.
    'exitDirect': exitDirect,
    // The exit's region; "" for the fastest.
    'exitRegion': exitRegion,
    // Tor type: direct, a built-in bridge transport, or custom (torCustomBridges).
    'torBridge': torBridge,
    'torCustomBridges': torCustomBridges,
    // Psiphon config fields for the mode, added to the app's psiphon_config.json (see PsiphonExit.kt).
    'psiphonConfig': psiphonConfig == null ? null : jsonEncode(psiphonConfig),
    // Worker's Browser Dialer: Xray's WebSockets are opened by a WebView (see BrowserDialer.kt).
    'browserDialer': browserDialer,
    });
  }

  /// The end of Xray's log for the current/last connection.
  static Future<String> readLog({String log = 'xray'}) async =>
      Platform.isWindows ? _WindowsVpnBackend.readLog() : await _methods.invokeMethod<String>('readLog', {'log': log}) ?? '';

/// Bytes in each log ("xray", "tor", "psiphon") since the last connect.
  static Future<Map<String, int>> logSizes() async =>
      Platform.isWindows ? _WindowsVpnBackend.logSizes() : (await _methods.invokeMapMethod<String, int>('logSizes')) ?? const {};

static Future<void> clearLog() => Platform.isWindows ? _WindowsVpnBackend.clearLog() : _methods.invokeMethod('clearLog');

  /// Saves [content] as [name] and opens the share sheet so the user picks an app.
  static Future<void> shareFile({required String name, required String content, String title = 'Share'}) =>
      Platform.isWindows
          ? _WindowsVpnBackend.saveFile(name: name, content: content).then<void>((_) {})
          : _methods.invokeMethod('shareFile', {'name': name, 'content': content, 'title': title});

  /// Saves [content] as [name] in Downloads (Android 7-9: a Save-as screen). Returns where
  /// it was saved, or null if the user cancelled.
  static Future<String?> saveFile({required String name, required String content}) =>
      Platform.isWindows
          ? _WindowsVpnBackend.saveFile(name: name, content: content)
          : _methods.invokeMethod<String>('saveFile', {'name': name, 'content': content});

  /// Opens the system file picker and returns the chosen file's name and text, or null if cancelled.
  static Future<({String name, String content})?> pickFile() async {
    if (Platform.isWindows) return _WindowsVpnBackend.pickFile();
    final file = await _methods.invokeMapMethod<String, String>('pickFile');
    if (file == null) return null;
    return (name: file['name'] ?? '', content: file['content'] ?? '');
  }

  static Future<void> stop() => Platform.isWindows ? _WindowsVpnBackend.stop() : _methods.invokeMethod('stop');

/// Starts the setup wizard's Tor with [bridges]; returns its HTTP proxy port (SetupTor.kt).
  static Future<int> startSetupTor(List<String> bridges) async {
    if (Platform.isWindows) throw UnsupportedError('Tor setup is not available in the Windows preview.');
    return await _methods.invokeMethod<int>('startSetupTor', {'bridges': bridges}) ?? 0;
  }

  /// The setup wizard's Tor: bootstrap progress (0-100), whether it runs, and why it stopped.
  static Future<({int progress, bool running, String? error})> setupTorStatus() async {
    if (Platform.isWindows) return (progress: 0, running: false, error: 'Tor is not available in the Windows preview.');
    final m = await _methods.invokeMapMethod<String, dynamic>('setupTorStatus') ?? const {};
    return (progress: (m['progress'] as int?) ?? 0, running: m['running'] == true, error: m['error'] as String?);
  }

  static Future<void> stopSetupTor() => Platform.isWindows ? Future.value() : _methods.invokeMethod('stopSetupTor');

  /// Opens [url] in the browser; false if nothing could handle it.
  static Future<bool> openUrl(String url) async {
    if (Platform.isWindows) return _WindowsVpnBackend.openUrl(url);
    try {
      return await _methods.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Domain Fronting's CA files (bpb-cert.crt / .key) are in the app's storage.
  static Future<bool> mitmCaExists() async => Platform.isWindows ? false : await _methods.invokeMethod<bool>('mitmCaExists') ?? false;

  static Future<void> saveMitmCa(MitmCa ca) => Platform.isWindows ? Future.error(UnsupportedError('Windows certificate installation is not implemented yet.')) : _methods.invokeMethod('saveMitmCa', {'cert': ca.cert, 'key': ca.key});

  /// Opens Android's CA install; on Android 11+ after saving bpb-cert.crt to Downloads,
  /// whose path it returns.
  static Future<String?> installMitmCa() => Platform.isWindows ? Future.value(null) : _methods.invokeMethod<String>('installMitmCa');

  /// Replaces Xray's geo files (geoip.dat, geosite.dat) with [files], each checked against its
  /// SHA-256 (hex) first: none is replaced unless all match. Xray uses them from its next start.
  static Future<void> saveGeoAssets(Map<String, ({Uint8List data, String sha256})> files) =>
      Platform.isWindows
          ? _WindowsVpnBackend.saveGeoAssets(files)
          : _methods.invokeMethod('saveGeoAssets', {
              'files': {
                for (final e in files.entries) e.key: {'data': e.value.data, 'sha256': e.value.sha256},
              },
            });

/// The cores' versions, from their own reports: Xray (e.g. 26.10.21) and
  /// the Psiphon (its core's module version) and Tor ("Tor version …") binaries; empty if unknown.
  static Future<({String xray, String psiphon, String tor})> versions() async {
    if (Platform.isWindows) return (xray: '', psiphon: '', tor: '');
    final m = await _methods.invokeMapMethod<String, String>('versions') ?? const {};
    return (xray: m['xray'] ?? '', psiphon: m['psiphon'] ?? '', tor: m['tor'] ?? '');
  }

  /// The installed app's version (from pubspec.yaml) and the phone's ABIs, preferred first.
  static Future<({String version, List<String> abis})> appInfo() async {
    if (Platform.isWindows) return (version: '1.0.0', abis: <String>[]);
    final m = await _methods.invokeMapMethod<String, dynamic>('appInfo') ?? const {};
    return (
      version: '${m['version'] ?? ''}',
      abis: (m['abis'] as List? ?? const []).map((e) => '$e').toList(),
    );
  }

  /// Delay in ms through the running tunnel.
  static Future<int> measureDelay() async {
    if (Platform.isWindows) return _WindowsVpnBackend.measureDelay();
    final ms = await _methods.invokeMethod<int>('measureDelay');
    return ms ?? -1;
  }

  /// Proxied traffic: bytes in the last second and since connecting, sampled by the
  /// VPN service (which also shows proxy and direct rates in its notification).
  static Future<({int up, int down, int totalUp, int totalDown})> traffic() async {
    if (Platform.isWindows) return (up: 0, down: 0, totalUp: 0, totalDown: 0);
    final m = await _methods.invokeMapMethod<String, int>('trafficStats');
    return (
      up: m?['proxyUp'] ?? 0,
      down: m?['proxyDown'] ?? 0,
      totalUp: m?['proxyUpTotal'] ?? 0,
      totalDown: m?['proxyDownTotal'] ?? 0,
    );
  }

  static Future<List<InstalledApp>> installedApps() async {
    if (Platform.isWindows) return const [];
    final list = await _methods.invokeListMethod<Map>('installedApps') ?? const [];
    return list
        .map(
          (m) => InstalledApp(
            m['package'] as String,
            m['label'] as String,
            m['system'] as bool? ?? false,
            m['icon'] as Uint8List?,
          ),
        )
        .toList();
  }
}


/// Windows v1 backend: local Xray proxy mode. Unsupported modes fail closed.
class _WindowsVpnBackend {
  static const _port = 10808;
  static const _key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static final _events = StreamController<VpnStateEvent>.broadcast();
  static Stream<VpnStateEvent> get states => _events.stream;
  static Process? _process;
  static String _log = '';
  static bool _stopping = false;
  static Future<void>? _recovery;
  static Directory? _appDir;
  static Directory? _runtimeDir;

  static void _emit(VpnStatus status, {String? error, DateTime? at}) =>
      _events.add(VpnStateEvent(status, error, at, null));

  static Future<Directory> _dataDir() async {
    final root = Platform.environment['LOCALAPPDATA'] ?? Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    final dir = Directory('$root${Platform.pathSeparator}BPB${Platform.pathSeparator}Windows');
    await dir.create(recursive: true);
    return dir;
  }

  static Future<void> recover() => _recovery ??= _recover();

  static Future<void> _recover() async {
    if (_process != null) return;
    final dir = await _dataDir();
    _appDir = dir;
    final session = File('${dir.path}${Platform.pathSeparator}session.json');
    if (await session.exists()) {
      try {
        final saved = jsonDecode(await session.readAsString());
        final pid = saved is Map ? saved['pid'] : null;
        if (pid is int && pid > 0) {
          await Process.run('taskkill.exe', ['/PID', '$pid', '/T', '/F']);
        }
      } catch (error) {
        _append('Stale Xray session recovery warning: $error\\n');
      }
      await session.delete();
    }
    try {
      await _restoreProxy();
    } catch (error) {
      _append('Windows proxy restore failed: $error\\n');
    }
  }

  static Future<bool> prepare({required bool vpn}) async {
    await recover();
    // Let start() show the explicit unsupported-TUN message instead of a fake permission error.
    return true;
  }

  static Future<void> start({required Map<String, dynamic> config, required bool proxyOnly, required String? exit, required bool browserDialer}) async {
    if (!proxyOnly) throw StateError('Windows preview supports Proxy mode only. VPN/TUN is not available yet.');
    if (exit != null || browserDialer) throw StateError('Psiphon, Tor, and Browser Dialer are not supported in this Windows preview.');
    final ins = config['inbounds'];
    if (ins is! List || !ins.any((v) => v is Map && v['tag'] == 'mixed-in' && v['port'] == _port)) {
      throw StateError('Expected Xray mixed inbound on 127.0.0.1:$_port was not found.');
    }
    if (_process != null) await stop();
    _emit(VpnStatus.connecting);
    _log = '';
    _stopping = false;
    final installDir = File(Platform.resolvedExecutable).parent;
    final runtime = Directory('${installDir.path}${Platform.pathSeparator}data');
    final exe = File('${runtime.path}${Platform.pathSeparator}xray.exe');
    if (!await exe.exists()) throw StateError('Missing ${exe.path}; rebuild the Windows package.');
    final appDir = await _dataDir();
    _appDir = appDir;
    _runtimeDir = runtime;
    final configFile = File('${appDir.path}${Platform.pathSeparator}config.json');
    await configFile.writeAsString(jsonEncode(config), flush: true);
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final getCurrentProcessId = kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
      final parentPid = getCurrentProcessId();
      final p = await Process.start(
        exe.path,
        ['-config', configFile.path, '-asset-dir', runtime.path, '-parent-pid', '$parentPid'],
        workingDirectory: installDir.path,
      );
      _process = p;
      p.stdout.transform(utf8.decoder).listen(_append);
      p.stderr.transform(utf8.decoder).listen(_append);
      p.exitCode.then((code) async {
        if (!identical(_process, p)) return;
        _process = null;
        await _restoreProxy();
        final dir = _appDir;
        if (dir != null) {
          final session = File('${dir.path}${Platform.pathSeparator}session.json');
          if (await session.exists()) await session.delete();
        }
        if (!_stopping) _emit(VpnStatus.disconnected, error: code == 0 ? null : 'Xray exited with code $code.');
        _stopping = false;
      });
      var ready = false;
      final until = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(until) && _process != null) {
        try {
          final socket = await Socket.connect('127.0.0.1', _port, timeout: const Duration(milliseconds: 400));
          socket.destroy();
          ready = true;
          break;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      if (!ready) throw StateError('Xray did not open its proxy port. See the Xray log.');
      await _applyProxy();
      _emit(VpnStatus.connected, at: DateTime.now());
    } catch (e) {
      final p = _process;
      _process = null;
      p?.kill();
      await _restoreProxy();
      _emit(VpnStatus.disconnected, error: '$e');
      rethrow;
    }
  }

  static void _append(String s) {
    _log += s;
    if (_log.length > 512 * 1024) _log = _log.substring(_log.length - 512 * 1024);
  }

  static Future<Map<String, Map<String, String>>> _snapshot() async {
    final values = <String, Map<String, String>>{};
    for (final name in ['ProxyEnable', 'ProxyServer', 'ProxyOverride']) {
      final r = await Process.run('reg.exe', ['query', _key, '/v', name]);
      final m = RegExp('^\\s*$name\\s+(REG_DWORD|REG_SZ)\\s+(.+?)\\s*\\r?\\n', multiLine: true, caseSensitive: false).firstMatch(r.stdout.toString());
      if (r.exitCode == 0 && m != null) values[name] = {'type': m.group(1)!, 'data': m.group(2)!};
    }
    return values;
  }

  static Future<void> _writeReg(String name, String type, String data) async {
    final r = await Process.run('reg.exe', ['add', _key, '/v', name, '/t', type, '/d', data, '/f']);
    if (r.exitCode != 0) throw StateError('Unable to change Windows proxy setting $name: ${r.stderr}');
  }

  static Future<void> _refresh() async {
    const script = r'''
$src = @"
using System;
using System.Runtime.InteropServices;
public static class BpbWinInet {
 [DllImport("wininet.dll", SetLastError=true)]
 public static extern bool InternetSetOption(IntPtr h, int option, IntPtr buffer, int length);
}
"@
Add-Type -TypeDefinition $src
[BpbWinInet]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0) | Out-Null
[BpbWinInet]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0) | Out-Null
''';
    await Process.run('powershell.exe', ['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command',script]);
  }

  static Future<void> _applyProxy() async {
    final dir = _appDir ?? await _dataDir();
    final backup = File('${dir.path}${Platform.pathSeparator}proxy-backup.json');
    if (!await backup.exists()) await backup.writeAsString(jsonEncode(await _snapshot()), flush: true);
    final process = _process;
    if (process != null) {
      final session = File('${dir.path}${Platform.pathSeparator}session.json');
      await session.writeAsString(jsonEncode({'pid': process.pid}), flush: true);
    }
    await _writeReg('ProxyServer', 'REG_SZ', '127.0.0.1:$_port');
    await _writeReg('ProxyOverride', 'REG_SZ', '<local>;localhost;127.*');
    await _writeReg('ProxyEnable', 'REG_DWORD', '1');
    await _refresh();
  }

  static Future<void> _restoreProxy() async {
    final dir = _appDir ?? await _dataDir();
    final backup = File('${dir.path}${Platform.pathSeparator}proxy-backup.json');
    if (!await backup.exists()) return;
    final raw = jsonDecode(await backup.readAsString());
    if (raw is Map) {
      for (final name in ['ProxyEnable','ProxyServer','ProxyOverride']) {
        final v = raw[name];
        if (v is Map && v['type'] is String && v['data'] is String) {
          await _writeReg(name, v['type'] as String, v['data'] as String);
        } else {
          await Process.run('reg.exe', ['delete', _key, '/v', name, '/f']);
        }
      }
      await _refresh();
    }
    await backup.delete();
  }

  static Future<void> stop() async {
    _stopping = true;
    _emit(VpnStatus.disconnecting);
    final p = _process;
    _process = null;
    if (p != null) {
      p.kill();
      try { await p.exitCode.timeout(const Duration(seconds: 5)); } on TimeoutException { p.kill(ProcessSignal.sigkill); }
    }
    await _restoreProxy();
    final dir = _appDir;
    if (dir != null) {
      for (final name in ['config.json', 'session.json']) {
        final f = File('${dir.path}${Platform.pathSeparator}$name');
        if (await f.exists()) await f.delete();
      }
    }
    _stopping = false;
    _emit(VpnStatus.disconnected);
  }

  static Future<String> readLog() async => _log;
  static Future<Map<String,int>> logSizes() async => {'xray': utf8.encode(_log).length};
  static Future<void> clearLog() async { _log = ''; }
  static Future<bool> openUrl(String url) async {
    final u = Uri.tryParse(url);
    if (u == null || !{'http','https'}.contains(u.scheme)) return false;
    final p = await Process.start('explorer.exe', [url], mode: ProcessStartMode.detached);
    return p.pid > 0;
  }
  static Future<String?> saveFile({required String name, required String content}) async {
    final home = Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
    final downloads = Directory('$home${Platform.pathSeparator}Downloads');
    await downloads.create(recursive: true);
    final safeName = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final file = File('${downloads.path}${Platform.pathSeparator}${safeName.isEmpty ? 'bpb-export.txt' : safeName}');
    await file.writeAsString(content, flush: true);
    return file.path;
  }
  static Future<({String name, String content})?> pickFile() async {
    const script = r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = "Open BPB configuration"
$dialog.Filter = "Configuration files (*.*)|*.*"
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::WriteLine($dialog.FileName) }
''';
    final result = await Process.run('powershell.exe', ['-NoProfile','-STA','-NonInteractive','-Command',script]);
    final path = result.stdout.toString().trim();
    if (result.exitCode != 0 || path.isEmpty) return null;
    final file = File(path);
    return (name: file.uri.pathSegments.last, content: await file.readAsString());
  }
  static Future<int> measureDelay() async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    c.findProxy = (_) => 'PROXY 127.0.0.1:$_port';
    try {
      final started = DateTime.now();
      final r = await (await c.getUrl(Uri.parse('https://www.gstatic.com/generate_204'))).close().timeout(const Duration(seconds: 12));
      await r.drain<void>();
      return r.statusCode == 204 || r.statusCode == 200 ? DateTime.now().difference(started).inMilliseconds : -1;
    } catch (_) { return -1; } finally { c.close(force: true); }
  }
  static Future<void> saveGeoAssets(Map<String, ({Uint8List data, String sha256})> files) async {
    final validated = <String, Uint8List>{};
    for (final e in files.entries) {
      if (!{'geoip.dat', 'geosite.dat'}.contains(e.key)) continue;
      final digest = SHA256Digest().process(e.value.data);
      final actual = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (actual != e.value.sha256.toLowerCase()) {
        throw StateError('Checksum mismatch for ${e.key}; no geo files were replaced.');
      }
      validated[e.key] = e.value.data;
    }
    final dir = _runtimeDir ?? Directory('${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}data');
    for (final entry in validated.entries) {
      await File('${dir.path}${Platform.pathSeparator}${entry.key}').writeAsBytes(entry.value, flush: true);
    }
  }
}

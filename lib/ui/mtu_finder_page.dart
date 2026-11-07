import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/mtu_finder.dart';

class MtuFinderPage extends StatefulWidget {
  const MtuFinderPage({super.key});

  @override
  State<MtuFinderPage> createState() => _MtuFinderPageState();
}

class _MtuFinderPageState extends State<MtuFinderPage> {
  final _targets = TextEditingController(text: MtuFinder.defaults.join(' '));
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _report;

  @override
  void dispose() {
    _targets.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() { _busy = true; _error = null; _report = null; });
    try {
      final report = await const MtuFinder().run(MtuFinder.parseTargets(_targets.text));
      if (mounted) setState(() => _report = report);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    final report = _report;
    if (report == null) return;
    await Clipboard.setData(ClipboardData(text: MtuFinder.encodeReport(report)));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('MTU report copied as JSON.')),
    );
  }

  Future<void> _save() async {
    final report = _report;
    if (report == null) return;
    try {
      final root = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
      final dir = Directory('$root\\BPB-VPN\\diagnostics');
      await dir.create(recursive: true);
      final file = File('${dir.path}\\mtu_result.json');
      await file.writeAsString(MtuFinder.encodeReport(report));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved: ${file.path}')),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save report: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Scaffold(
      appBar: AppBar(title: const Text('Path MTU Finder')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Estimate the IPv4 path MTU to selected public endpoints using Windows ping with Don’t Fragment. This is a diagnostic only; it does not change your network settings.'),
          const SizedBox(height: 16),
          TextField(
            controller: _targets,
            minLines: 2,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'IPv4 targets',
              hintText: '1.1.1.1 8.8.8.8',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _run,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.network_check),
            label: Text(_busy ? 'Testing path MTU…' : 'Run MTU test'),
          ),
          if (_busy) const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('This may take a few minutes. ICMP filtering can affect results.'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (report != null) ...[
            const SizedBox(height: 24),
            Text('Recommended MTU', style: Theme.of(context).textTheme.titleMedium),
            Text('${report['recommended_v2ray_mtu']}', style: Theme.of(context).textTheme.displaySmall),
            Text('Conservative detected path MTU: ${report['detected_path_mtu']} bytes · safety margin: ${report['safety_margin']}'),
            const SizedBox(height: 16),
            for (final item in (report['mtu_results'] as List))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${item['host']}'),
                subtitle: Text('Path MTU: ${item['path_mtu']} bytes'),
                trailing: const Icon(Icons.check_circle_outline),
              ),
            if ((report['stability_results'] as List).isNotEmpty) ...[
              const Divider(),
              Text('Stability', style: Theme.of(context).textTheme.titleMedium),
              for (final item in (report['stability_results'] as List))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${item['host']} · ${item['status']}'),
                  subtitle: Text('Packet loss: ${item['loss_percent']}% (${item['received']}/${item['sent']} received)'),
                ),
            ],
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(onPressed: _copy, icon: const Icon(Icons.copy), label: const Text('Copy JSON')),
              OutlinedButton.icon(onPressed: _save, icon: const Icon(Icons.save_alt), label: const Text('Save report')),
            ]),
            const SizedBox(height: 8),
            const Text('This is a normal-internet estimate, not the MTU of a VPN tunnel. Windows proxy mode has no virtual tunnel interface, so the value is not applied automatically.', style: TextStyle(fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

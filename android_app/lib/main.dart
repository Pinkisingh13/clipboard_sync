import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clipboard Sync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _ConnectionAttempt {
  const _ConnectionAttempt(this.code, {this.forget = false});

  final String? code;
  final bool forget;
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  static const platform = MethodChannel('clipboard_sync');

  BonsoirDiscovery? _discovery;
  Timer? _statusTimer;
  final List<Map<String, dynamic>> _servers = [];
  List<Map<String, dynamic>> _savedDevices = [];

  String _syncState = 'stopped';
  String _statusMessage = 'Sync is stopped';
  bool _isConnecting = false;
  bool _connectionDialogOpen = false;
  bool _nativeStatusUnavailable = false;
  Map<String, dynamic>? _imageOffer;
  Timer? _imageOfferExpiryTimer;

  bool get _isDiscovering => _discovery != null;
  bool get _serviceCanStop => {
    'connecting',
    'pairing',
    'authenticating',
    'connected',
    'reconnecting',
  }.contains(_syncState);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedDevices();
    _refreshNativeStatus();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _refreshNativeStatus(),
    );
  }

  Future<void> _refreshNativeStatus() async {
    await _refreshImageOffer();
    try {
      final raw = await platform.invokeMapMethod<String, dynamic>(
        'getSyncStatus',
      );
      if (!mounted || raw == null || _connectionDialogOpen) return;
      final state = raw['state'] as String? ?? 'stopped';
      final message = raw['message'] as String? ?? 'Sync is stopped';
      if (_syncState == state && _statusMessage == message) return;
      setState(() {
        _syncState = state;
        _statusMessage = message;
        _isConnecting = false;
      });
      if (state == 'connected') {
        _loadSavedDevices();
      }
    } on MissingPluginException {
      if (!mounted || _nativeStatusUnavailable) return;
      setState(() {
        _nativeStatusUnavailable = true;
        _syncState = 'error';
        _statusMessage =
            'Android native code is outdated. Stop Flutter and run the app again.';
      });
    } on PlatformException catch (error) {
      debugPrint('Could not read sync status: ${error.message}');
    }
  }

  Future<void> _refreshImageOffer() async {
    try {
      final offer = await platform.invokeMapMethod<String, dynamic>(
        'getPendingImageOffer',
      );
      if (!mounted) return;
      final isNewOffer = offer != null && offer['id'] != _imageOffer?['id'];
      if (isNewOffer) {
        _imageOfferExpiryTimer?.cancel();
        _imageOfferExpiryTimer = Timer(const Duration(minutes: 2), () {
          _respondToImageOffer(false);
        });
      }
      if (offer == null) _imageOfferExpiryTimer?.cancel();
      setState(() => _imageOffer = offer);
    } on MissingPluginException {
      // Native app must be rebuilt once after this feature is added.
    } on PlatformException catch (error) {
      debugPrint('Could not read image offer: ${error.message}');
    }
  }

  Future<void> _loadSavedDevices() async {
    try {
      final raw = await platform.invokeListMethod<dynamic>('listPairedDevices');
      if (!mounted) return;
      setState(() {
        _savedDevices = (raw ?? [])
            .whereType<Map>()
            .map(
              (device) => Map<String, dynamic>.from(
                device.map((key, value) => MapEntry(key.toString(), value)),
              ),
            )
            .toList();
      });
    } on MissingPluginException {
      if (!mounted || _nativeStatusUnavailable) return;
      setState(() {
        _nativeStatusUnavailable = true;
        _syncState = 'error';
        _statusMessage =
            'Android native code is outdated. Stop Flutter and run the app again.';
      });
    } on PlatformException catch (error) {
      debugPrint('Could not load saved pairings: ${error.message}');
    }
  }

  Future<void> startDiscovering() async {
    if (_isDiscovering || _serviceCanStop) return;
    setState(() {
      _servers.clear();
      _syncState = 'discovering';
      _statusMessage = 'Looking for a Mac on this network...';
    });

    final discovery = BonsoirDiscovery(type: '_clipboardsync._tcp');
    _discovery = discovery;
    await discovery.initialize();

    discovery.eventStream!.listen((event) async {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          event.service.resolve(discovery.serviceResolver);
          break;
        case BonsoirDiscoveryServiceResolvedEvent():
          final fingerprint = event.service.attributes['fp'];
          final paired = await hasPairing(fingerprint);
          if (!mounted || _discovery != discovery || _connectionDialogOpen) {
            return;
          }
          final server = <String, dynamic>{
            'name': event.service.name,
            'ip': event.service.hostAddress,
            'port': event.service.port,
            'fingerprint': fingerprint,
            'secure': event.service.attributes['tls'] == '1',
            'paired': paired,
          };
          setState(() {
            final index = _servers.indexWhere(
              (item) =>
                  item['fingerprint'] == fingerprint &&
                  item['ip'] == event.service.hostAddress,
            );
            if (index == -1) {
              _servers.add(server);
            } else {
              _servers[index] = server;
            }
          });
          break;
        case BonsoirDiscoveryServiceLostEvent():
          if (!mounted) return;
          setState(() {
            _servers.removeWhere((item) => item['name'] == event.service.name);
          });
          break;
        default:
          break;
      }
    });
    await discovery.start();
  }

  Future<void> _stopDiscovery() async {
    final discovery = _discovery;
    _discovery = null;
    await discovery?.stop();
  }

  Future<bool> hasPairing(String? fingerprint) async {
    if (fingerprint == null || fingerprint.isEmpty) return false;
    try {
      return await platform.invokeMethod<bool>('hasPairing', {
            'serverFingerprint': fingerprint,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('Could not read pairing status: ${error.message}');
      return false;
    }
  }

  Future<void> _startService(
    Map<String, dynamic> server,
    String? pairingCode,
  ) async {
    final fingerprint = server['fingerprint'] as String?;
    if (fingerprint == null || fingerprint.isEmpty) {
      setState(() {
        _syncState = 'error';
        _statusMessage = 'This Mac does not support secure sync.';
      });
      return;
    }
    try {
      await platform.invokeMethod<String>('startService', {
        'serverIp': server['ip'],
        'serverPort': server['port'],
        'serverFingerprint': fingerprint,
        'serverName': server['name'],
        'pairingCode': pairingCode,
      });
      await _stopDiscovery();
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _syncState = pairingCode == null ? 'connecting' : 'pairing';
        _statusMessage = pairingCode == null
            ? 'Connecting with saved pairing...'
            : 'Checking pairing code...';
      });
      if (pairingCode != null) {
        _waitForSavedPairing(fingerprint);
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _syncState = 'error';
        _statusMessage = error.message ?? 'Could not start sync.';
      });
    }
  }

  Future<void> _waitForSavedPairing(String fingerprint) async {
    for (final delay in const [
      Duration(milliseconds: 300),
      Duration(milliseconds: 700),
      Duration(seconds: 1),
      Duration(seconds: 2),
    ]) {
      await Future<void>.delayed(delay);
      if (!await hasPairing(fingerprint) || !mounted) continue;
      setState(() {
        for (final server in _servers) {
          if (server['fingerprint'] == fingerprint) server['paired'] = true;
        }
      });
      await _loadSavedDevices();
      return;
    }
  }

  Future<void> stopService() async {
    try {
      await _dismissImageOffer();
      await platform.invokeMethod<String>('stopService');
      await _stopDiscovery();
      if (!mounted) return;
      setState(() {
        _syncState = 'stopped';
        _statusMessage = 'Sync is stopped';
        _isConnecting = false;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _syncState = 'error';
        _statusMessage = error.message ?? 'Could not stop sync.';
      });
    }
  }

  Future<void> _respondToImageOffer(bool accept) async {
    final offer = _imageOffer;
    if (offer == null) return;
    try {
      await platform.invokeMethod('respondToImageOffer', {
        'id': offer['id'],
        'accept': accept,
      });
      _imageOfferExpiryTimer?.cancel();
      if (!mounted) return;
      setState(() => _imageOffer = null);
    } on PlatformException catch (error) {
      debugPrint('Could not respond to image offer: ${error.message}');
    }
  }

  Future<void> _dismissImageOffer() async {
    if (_imageOffer != null) {
      await _respondToImageOffer(false);
    }
  }

  Future<void> _confirmForget(
    String fingerprint, {
    required String deviceName,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Forget saved pairing?'),
        content: Text(
          'Remove the saved pairing for $deviceName? '
          'A new Mac pairing code will be required next time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Yes, forget'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _dismissImageOffer();
      await platform.invokeMethod<String>('forgetPairing', {
        'serverFingerprint': fingerprint,
      });
      if (!mounted) return;
      setState(() {
        _syncState = 'stopped';
        _statusMessage = 'Saved pairing removed. Enter a new Mac pairing code.';
        _servers
            .where((server) => server['fingerprint'] == fingerprint)
            .forEach((server) => server['paired'] = false);
      });
      await _loadSavedDevices();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved pairing removed successfully')),
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? 'Could not forget pairing.')),
      );
    }
  }

  Future<void> _showConnectionDialog(Map<String, dynamic> server) async {
    if (_isConnecting || _serviceCanStop) return;
    final paired = server['paired'] == true;
    String code = '';
    setState(() => _connectionDialogOpen = true);
    final choice = await showDialog<_ConnectionAttempt>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(paired ? 'Connect to saved Mac' : 'Pair this Mac'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                paired
                    ? 'Use saved pairing, or enter a new code to replace it.'
                    : 'Enter the six-digit code currently shown on your Mac.',
              ),
              const SizedBox(height: 12),
              TextField(
                keyboardType: TextInputType.number,
                maxLength: 6,
                onChanged: (value) {
                  setDialogState(() => code = value.trim());
                },
                decoration: const InputDecoration(
                  labelText: 'Mac pairing code',
                  hintText: 'Example: 123456',
                ),
              ),
            ],
          ),
          actions: [
            if (paired)
              TextButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  const _ConnectionAttempt(null, forget: true),
                ),
                child: const Text('Forget pairing'),
              ),
            if (paired)
              TextButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  const _ConnectionAttempt(null),
                ),
                child: const Text('Use saved pairing'),
              ),
            FilledButton(
              onPressed: code.length == 6
                  ? () => Navigator.pop(dialogContext, _ConnectionAttempt(code))
                  : null,
              child: const Text('Pair with code'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _connectionDialogOpen = false);
    if (choice == null) return;
    if (choice.forget) {
      await _confirmForget(
        server['fingerprint'] as String,
        deviceName: server['name'] as String,
      );
      return;
    }
    setState(() => _isConnecting = true);
    await _startService(server, choice.code);
  }

  IconData get _statusIcon => switch (_syncState) {
    'connected' => Icons.verified_user,
    'connecting' ||
    'pairing' ||
    'authenticating' ||
    'reconnecting' => Icons.sync,
    'error' || 'pairingRequired' => Icons.error_outline,
    _ => Icons.circle_outlined,
  };

  Color _statusColor(BuildContext context) => switch (_syncState) {
    'connected' => Colors.green,
    'connecting' ||
    'pairing' ||
    'authenticating' ||
    'reconnecting' => Theme.of(context).colorScheme.primary,
    'error' || 'pairingRequired' => Theme.of(context).colorScheme.error,
    _ => Colors.grey,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Clipboard Sync'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Mac connection',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: _serviceCanStop
                    ? stopService
                    : (_isDiscovering ? null : startDiscovering),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _serviceCanStop ? Colors.red : Colors.green,
                  foregroundColor: Colors.white,
                ),
                child: Text(
                  _serviceCanStop
                      ? 'Stop Sync'
                      : (_isDiscovering ? 'Finding Mac...' : 'Start Sync'),
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ),
            const SizedBox(height: 20),
            _statusCard(context),
            if (_syncState == 'connected') ...[
              const SizedBox(height: 12),
              const Text(
                'To send an Android image: copy it in another app, then return '
                'to Clipboard Sync. Choose Receive or Ignore on your Mac.',
                style: TextStyle(color: Colors.black54),
              ),
            ],
            if (_imageOffer != null) _imageOfferCard(),
            if (_savedDevices.isNotEmpty) ...[
              const SizedBox(height: 24),
              const Text(
                'Saved pairings',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ..._savedDevices.map(
                (device) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.computer),
                    title: Text(device['name'] as String? ?? 'Saved Mac'),
                    subtitle: Text(
                      'Fingerprint: ${_shortFingerprint(device['fingerprint'] as String?)}',
                    ),
                    trailing: IconButton(
                      tooltip: 'Forget saved pairing',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _confirmForget(
                        device['fingerprint'] as String,
                        deviceName: device['name'] as String? ?? 'this Mac',
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (_isDiscovering && !_serviceCanStop) ...[
              const SizedBox(height: 24),
              const Text(
                'Found Macs',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              if (_servers.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 12),
                      Text('Looking for a Mac on this network...'),
                    ],
                  ),
                ),
              ..._servers.map(
                (server) => Card(
                  child: ListTile(
                    leading: Icon(
                      server['secure'] == true
                          ? Icons.lock_outline
                          : Icons.warning_amber,
                    ),
                    title: Text(server['name'] as String),
                    subtitle: Text(
                      '${server['ip']}:${server['port']}\n'
                      '${server['paired'] == true ? 'Saved pairing available' : 'New pairing code required'}\n'
                      'Fingerprint: ${_shortFingerprint(server['fingerprint'] as String?)}',
                    ),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showConnectionDialog(server),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(_statusIcon, color: _statusColor(context)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _statusTitle(),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 3),
                Text(_statusMessage),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _imageOfferCard() {
    final offer = _imageOffer!;
    final size = (offer['size'] as num? ?? 0).toInt();
    return Card(
      margin: const EdgeInsets.only(top: 20),
      color: Colors.blue.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Image copied on Mac',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
            ),
            const SizedBox(height: 6),
            Text('${offer['name']} (${(size / 1024).round()} KB)'),
            const Text('This offer expires in 2 minutes.'),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _respondToImageOffer(false),
                  child: const Text('Ignore'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => _respondToImageOffer(true),
                  child: const Text('Receive'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _statusTitle() => switch (_syncState) {
    'connected' => 'Securely connected',
    'connecting' => 'Connecting',
    'pairing' => 'Pairing',
    'authenticating' => 'Verifying pairing',
    'reconnecting' => 'Reconnecting',
    'pairingRequired' => 'Pairing code needed',
    'error' => 'Connection problem',
    'discovering' => 'Finding Mac',
    _ => 'Sync stopped',
  };

  String _shortFingerprint(String? value) {
    if (value == null || value.length < 16) return value ?? 'Unavailable';
    return '${value.substring(0, 8)}…${value.substring(value.length - 8)}';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _imageOfferExpiryTimer?.cancel();
    _stopDiscovery();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _dismissImageOffer();
    }
  }
}

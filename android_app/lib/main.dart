import 'dart:developer';
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

class _HomeScreenState extends State<HomeScreen> {
  static const platform = MethodChannel('clipboard_sync');
  BonsoirDiscovery? _bonsoirDiscovery;
  List<Map<String, dynamic>> serviceslist = [];

  bool isServiceRunning = false;
  bool isConnecting = false;
  String statusMessage = 'Not connected';

  Future<void> startDiscovering() async {
    setState(() {
      serviceslist.clear();
      statusMessage = 'Looking for Mac...';
    });

    _bonsoirDiscovery = BonsoirDiscovery(type: '_clipboardsync._tcp');

    await _bonsoirDiscovery?.initialize();

    _bonsoirDiscovery?.eventStream!.listen((event) async {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          log('Service found but not yet resolved: ${event.service.name}');
          event.service?.resolve(_bonsoirDiscovery!.serviceResolver);
          break;

        case BonsoirDiscoveryServiceResolvedEvent():
          log('Service resolved successfully: ${event.service?.name}');
          log('IP Addresses: ${event.service?.hostAddresses}');
          log('Port: ${event.service?.port}');

          if (event.service != null) {
            setState(() {
              final existingIndex = serviceslist.indexWhere(
                (server) =>
                    server['name'] == event.service.name &&
                    server['ip'] == event.service.hostAddress,
              );
              if (existingIndex == -1) {
                serviceslist.add({
                  'name': event.service.name,
                  'ip': event.service.hostAddress,
                  'port': event.service.port,
                });
              }
            });
          }

          break;

        case BonsoirDiscoveryServiceLostEvent():
          log('Service lost from the network: ${event.service?.name}');
          setState(() {
            serviceslist.removeWhere(
              (server) => server['name'] == event.service?.name,
            );
          });
          break;

        default:
          log('Other event occurred: $event');
          break;
      }
    });

    await _bonsoirDiscovery?.start();
  }

  Future<void> startService(String ip, int port) async {
    try {
      final String result = await platform.invokeMethod('startService', {
        'serverIp': ip,
        'serverPort': port,
      });

      setState(() {
        isServiceRunning = true;
        isConnecting = false;
        statusMessage = result;
      });

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(result)));
      }
    } on PlatformException catch (e) {
      setState(() {
        isConnecting = false;
        statusMessage = 'Error: ${e.message}';
      });

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(' ${e.message}')));
      }
    }
  }

  Future<void> stopService() async {
    try {
      await _bonsoirDiscovery?.stop();
      _bonsoirDiscovery = null;
      final String result = await platform.invokeMethod('stopService');

      setState(() {
        isServiceRunning = false;
        statusMessage = result;
      });

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(' $result')));
      }
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${e.message}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Clipboard Sync Android App'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Mac Server Settings',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 32),
            Center(
              child: SizedBox(
                width: 200,
                height: 50,
                child: ElevatedButton(
                  onPressed: (_bonsoirDiscovery != null && !isServiceRunning)
                      ? null
                      : (isServiceRunning ? stopService : startDiscovering),
                  style: ElevatedButton.styleFrom(
                    shape: BeveledRectangleBorder(
                      borderRadius: BorderRadiusGeometry.all(
                        Radius.circular(12),
                      ),
                    ),
                    backgroundColor: isServiceRunning
                        ? Colors.red
                        : Colors.green,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(
                    isServiceRunning ? 'Stop Sync' : 'Start Sync',
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
              ),
            ),

            if (_bonsoirDiscovery != null && !isServiceRunning) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Finding Mac server...',
                    style: TextStyle(color: Colors.grey, fontSize: 14),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),

            if (serviceslist.isNotEmpty && !isServiceRunning) ...[
              const SizedBox(height: 24),
              const Text(
                'Found Servers:',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              ...serviceslist.map((server) {
                return Card(
                  child: ListTile(
                    leading: Icon(Icons.computer, color: Colors.blue),
                    title: Text(server['name']),
                    subtitle: Text(server['ip']),
                    trailing: Icon(Icons.arrow_forward_ios),
                    onTap: () {
                      if (isConnecting || isServiceRunning) return;
                      setState(() {
                        isConnecting = true;
                      });
                      startService(server['ip'], server['port']);
                    },
                  ),
                );
              }),
            ],

            const SizedBox(height: 24),

            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Status',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        isServiceRunning
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        color: isServiceRunning ? Colors.green : Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          statusMessage,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (isServiceRunning) ...[
              const SizedBox(height: 24),
              const Text(
                'Connected! Copy text on either device to sync',
                style: TextStyle(
                  color: Color.fromARGB(255, 121, 120, 120),
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

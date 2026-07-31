import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
      home: const ServerScreen(),
    );
  }
}

class ServerScreen extends StatefulWidget {
  const ServerScreen({super.key});

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  bool isServerRunning = false;
  String statusMessage = 'Not started';
  String localIp = 'Finding...';
  int connectedClients = 0;
  HttpServer? _server;
  final List<WebSocketChannel> _clients = [];
  BonsoirBroadcast? _broadcast;

  @override
  void initState() {
    super.initState();
    _getLocalIp();
  }

  // Cross-platform clipboard helper functions
  Future<String> _readClipboard() async {
    try {
      if (Platform.isMacOS) {
        final result = await Process.run('pbpaste', []);
        return result.stdout.toString().trim();
      } else if (Platform.isWindows) {
        final result = await Process.run(
          'powershell',
          ['-command', 'Get-Clipboard'],
        );
        return result.stdout.toString().trim();
      } else if (Platform.isLinux) {
       
        final result = await Process.run(
          'xclip',
          ['-selection', 'clipboard', '-o'],
        );
        return result.stdout.toString().trim();
      }
    } catch (e) {
      print('Error reading clipboard: $e');
    }
    return '';
  }

  Future<void> _writeClipboard(String text) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('bash', ['-c', 'echo "$text" | pbcopy']);
      } else if (Platform.isWindows) {
        await Process.run(
          'powershell',
          ['-command', 'Set-Clipboard', '-Value', r'$text'],
        );
      } else if (Platform.isLinux) {
        await Process.run('bash', ['-c', 'echo "$text" | xclip -selection clipboard']);
      }
    } catch (e) {
      print('Error writing clipboard: $e');
    }
  }

  Future<void> startBonjoir() async {
    final bonsoircontent = BonsoirService(
      name: "clipboard sync service",
      type: '_clipboardsync._tcp',
      port: 8080,
    );

    _broadcast = BonsoirBroadcast(service: bonsoircontent);
    await _broadcast?.initialize();
    await _broadcast?.start();
  }

  Future<void> stopBonjoir() async {
    await _broadcast?.stop();
    _broadcast = null;
  }

  Future<void> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );

      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (!addr.isLoopback && addr.address.startsWith('192.168')) {
            setState(() {
              localIp = addr.address;
            });
            return;
          }
        }
      }
      setState(() {
        localIp = 'Not found';
      });
    } catch (e) {
      setState(() {
        localIp = 'Error';
      });
    }
  }

  Future<void> startServer() async {
    try {
      await startBonjoir();
      final ip = InternetAddress.anyIPv4;
      const port = 8080;

      var handler = webSocketHandler((WebSocketChannel webSocket) {
        setState(() {
          connectedClients++;
        });

        _clients.add(webSocket);
        String lastClipboard = '';
        Timer? pollingTimer;

        pollingTimer = Timer.periodic(const Duration(milliseconds: 100), (
          timer,
        ) async {
          String current = await _readClipboard();

          if (current != lastClipboard && current.isNotEmpty) {
            lastClipboard = current;
            webSocket.sink.add(current);
            print('📋 Sent to Android: $current');
          }
        });

        webSocket.stream.listen(
          (event) async {
            print('📱 Received from Android: $event');
            await _writeClipboard(event.toString());
            lastClipboard = event.toString();
          },
          onDone: () {
            pollingTimer?.cancel();
            _clients.remove(webSocket);
            setState(() {
              connectedClients--;
            });
            print('Client disconnected');
          },
        );
      });

      _server = await serve(handler, ip, port);

      setState(() {
        isServerRunning = true;
        statusMessage = 'Running on $localIp:$port';
      });

      print('🚀 Server started on $localIp:$port');
    } catch (e) {
      setState(() {
        statusMessage = 'Error: $e';
      });
    }
  }

  Future<void> stopServer() async {
    await _server?.close(force: true);

    for (var client in _clients) {
      await client.sink.close();
    }
    _clients.clear();

    await stopBonjoir();

    setState(() {
      isServerRunning = false;
      statusMessage = 'Stopped';
      connectedClients = 0;
    });

    print('Server stopped');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Clipboard Sync'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isServerRunning ? Icons.cloud_done : Icons.cloud_off,
                size: 100,
                color: isServerRunning ? Colors.green : Colors.grey,
              ),
              const SizedBox(height: 24),
              Text(
                isServerRunning ? 'Server Running' : 'Server Stopped',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    _buildInfoRow('Status', statusMessage),
                    const SizedBox(height: 8),
                    _buildInfoRow('Local IP', localIp),
                    const SizedBox(height: 8),
                    _buildInfoRow('Port', '8080'),
                    const SizedBox(height: 8),
                    _buildInfoRow(
                      'Connected Devices',
                      connectedClients.toString(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: 200,
                height: 50,
                child: ElevatedButton(
                  onPressed: isServerRunning ? stopServer : startServer,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isServerRunning
                        ? Colors.red
                        : Colors.green,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(
                    isServerRunning ? 'Stop Server' : 'Start Server',
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
              ),
              if (isServerRunning) ...[
                const SizedBox(height: 24),
                const Text(
                  'Open the Android app to connect automatically via mDNS',
                  style: TextStyle(color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                Container(
                  constraints: const BoxConstraints(maxWidth: 500),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.blue, width: 2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.science, color: Colors.blue, size: 20),
                          const SizedBox(width: 8),
                          const Text(
                            'Demo Test Area',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: Colors.blue,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Type here and copy to test clipboard sync:',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        maxLines: 3,
                        decoration: InputDecoration(
                          hintText: 'Type text here, then select and copy (Cmd+C)',
                          border: const OutlineInputBorder(),
                          filled: true,
                          fillColor: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Or paste here to see synced text from Android:',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        maxLines: 3,
                        decoration: InputDecoration(
                          hintText: 'Press Cmd+V to paste text from Android',
                          border: const OutlineInputBorder(),
                          filled: true,
                          fillColor: Colors.green[50],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('$label:', style: const TextStyle(fontWeight: FontWeight.bold)),
        Text(value),
      ],
    );
  }

  @override
  void dispose() {
    stopServer();
    super.dispose();
  }
}

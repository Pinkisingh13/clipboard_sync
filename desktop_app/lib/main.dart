import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/material.dart';
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
  Timer? _clipboardPollTimer;
  String _lastClipboard = '';

  @override
  void initState() {
    super.initState();
    _getLocalIp();
  }

  Future<String> _readClipboard() async {
    try {
      if (Platform.isMacOS) {
        final result = await Process.run('pbpaste', []);
        return result.stdout.toString().trim();
      } else if (Platform.isWindows) {
        final result = await Process.run('powershell', [
          '-command',
          'Get-Clipboard',
        ]);
        return result.stdout.toString().trim();
      } else if (Platform.isLinux) {
        final result = await Process.run('xclip', [
          '-selection',
          'clipboard',
          '-o',
        ]);
        return result.stdout.toString().trim();
      }
    } catch (e) {
      debugPrint('Error reading clipboard: $e');
    }
    return '';
  }

  Future<void> _writeClipboard(String text) async {
    try {
      if (Platform.isMacOS) {
    
        final process = await Process.start('pbcopy', []);
        process.stdin.add(utf8.encode(text));
        await process.stdin.close();
        await process.exitCode;
      } else if (Platform.isWindows) {
      
        final process = await Process.start('powershell', [
          '-NoProfile',
          '-Command',
          '[Console]::InputEncoding=[Text.UTF8Encoding]::new(); \$input | Set-Clipboard',
        ]);
        process.stdin.add(utf8.encode(text));
        await process.stdin.close();
        await process.exitCode;
      } else if (Platform.isLinux) {
        // Use stdin to avoid shell injection
        final process = await Process.start('xclip', [
          '-selection',
          'clipboard',
        ]);
        process.stdin.add(utf8.encode(text));
        await process.stdin.close();
        await process.exitCode;
      }
    } catch (e) {
      debugPrint('Error writing clipboard: $e');
    }
  }

  Future<void> startBonjoir() async {
    final bonsoircontent = BonsoirService(
      name: "clipboard sync ${Platform.localHostname}",
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

      String? candidateIp;
      int priority = 0;

      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.isLoopback) continue;

          final ip = addr.address;
          int currentPriority = 0;

          if (ip.startsWith('192.168.')) {
            currentPriority = 4;
          } else if (ip.startsWith('10.')) {
            currentPriority = 3;
          } else if (ip.startsWith('172.')) {
            final second = int.tryParse(ip.split('.')[1]) ?? 0;
            if (second >= 16 && second <= 31) {
              currentPriority = 2;
            }
          } else {
            currentPriority = 1;
          }

          if (currentPriority > priority) {
            priority = currentPriority;
            candidateIp = ip;
          }
        }
      }

      setState(() {
        localIp = candidateIp ?? 'Not found';
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

      _clipboardPollTimer = Timer.periodic(const Duration(milliseconds: 100), (
        timer,
      ) async {
        String current = await _readClipboard();

        if (current != _lastClipboard && current.isNotEmpty) {
          _lastClipboard = current;

          for (var client in _clients) {
            try {
              client.sink.add(current);
            } catch (e) {
              debugPrint('Error sending to client: $e');
            }
          }
          debugPrint('📋 Sent to ${_clients.length} client(s): $current');
        }
      });

      var handler = webSocketHandler((WebSocketChannel webSocket) {
        setState(() {
          connectedClients++;
        });

        _clients.add(webSocket);

        webSocket.stream.listen(
          (event) async {
            debugPrint('📱 Received from Android: $event');
            await _writeClipboard(event.toString());
            _lastClipboard = event.toString();
          },
          onDone: () {
            _clients.remove(webSocket);
            setState(() {
              connectedClients--;
            });
            debugPrint('Client disconnected');
          },
        );
      });

      _server = await serve(handler, ip, port);

      setState(() {
        isServerRunning = true;
        statusMessage = 'Running on $localIp:$port';
      });

      debugPrint('🚀 Server started on $localIp:$port');
    } catch (e) {
      setState(() {
        statusMessage = 'Error: $e';
      });
    }
  }

  Future<void> stopServer() async {
    _clipboardPollTimer?.cancel();
    _clipboardPollTimer = null;
    _lastClipboard = '';

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

    debugPrint('Server stopped');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Clipboard Sync Desktop App'),
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
                    shape: BeveledRectangleBorder(
                      borderRadius: BorderRadiusGeometry.all(
                        Radius.circular(12),
                      ),
                    ),
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
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                  textAlign: TextAlign.center,
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

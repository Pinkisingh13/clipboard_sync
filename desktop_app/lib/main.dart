import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bonsoir/bonsoir.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:desktop_app/security/desktop_identity.dart';
import 'package:desktop_app/security/pairing_store.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

({int? sentAt, String text}) _unwrapLatencyPayload(String raw) {
  if (!raw.startsWith('CS1|')) {
    return (sentAt: null, text: raw);
  }
  final secondBar = raw.indexOf('|', 4);
  if (secondBar < 0) {
    return (sentAt: null, text: raw);
  }
  final sentAt = int.tryParse(raw.substring(4, secondBar));
  return (sentAt: sentAt, text: raw.substring(secondBar + 1));
}

String _stripAllLatencyPrefixes(String raw) {
  var text = raw;
  var guard = 0;
  while (text.startsWith('CS1|') && guard < 64) {
    final next = _unwrapLatencyPayload(text).text;
    if (next == text) break;
    text = next;
    guard++;
  }
  return text;
}

String _randomToken() => base64UrlEncode(
  List<int>.generate(32, (_) => Random.secure().nextInt(256)),
).replaceAll('=', '');

String _proof(String secret, String challenge) => Hmac(
  sha256,
  utf8.encode(secret),
).convert(utf8.encode(challenge)).toString();

class _ClientSession {
  _ClientSession(this.channel);

  final WebSocketChannel channel;
  String? deviceId;
  String? challenge;
  String? pairingSecret;
  bool authenticated = false;
}

class _PendingImage {
  const _PendingImage({
    required this.bytes,
    required this.mime,
    required this.extension,
  });

  final Uint8List bytes;
  final String mime;
  final String extension;
}

class _IncomingImageOffer {
  const _IncomingImageOffer({
    required this.id,
    required this.name,
    required this.mime,
    required this.size,
    required this.sha256,
  });

  final String id;
  final String name;
  final String mime;
  final int size;
  final String sha256;
}

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
  String certificateFingerprint = 'Preparing secure identity...';
  String imageTransferStatus = 'No image transfer activity';
  int connectedDevices = 0;
  HttpServer? _server;
  final List<_ClientSession> _clients = [];
  BonsoirBroadcast? _broadcast;
  Timer? _clipboardPollTimer;
  String _lastClipboard = '';
  int _lastMacChangeToken = -1;
  bool _pollInFlight = false;
  static const _macClipboard = MethodChannel('clipboard');
  static const _imageClipboard = MethodChannel('clipboard_image');
  DesktopIdentity? _identity;
  final PairingStore _pairingStore = PairingStore();
  String? _pairingCode;
  Timer? _pairingCodeTimer;
  final Map<String, _PendingImage> _pendingImages = {};
  final Map<String, Timer> _pendingImageTimers = {};
  _IncomingImageOffer? _incomingImageOffer;
  BytesBuilder? _incomingImageBytes;
  Timer? _incomingImageTimer;
  bool _incomingImageAccepted = false;

  @override
  void initState() {
    super.initState();
    _getLocalIp();
    _loadIdentity();
  }

  Future<void> _loadIdentity() async {
    try {
      final identity = await DesktopIdentity.loadOrCreate();
      if (!mounted) return;
      setState(() {
        _identity = identity;
        certificateFingerprint = identity.fingerprint;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        certificateFingerprint = 'Unavailable';
        statusMessage = 'Secure identity error: $error';
      });
    }
  }

  Future<int> _macChangeToken() async {
    final token = await _macClipboard.invokeMethod<int>('changeToken');
    return token ?? 0;
  }

  Future<String> _readClipboard() async {
    try {
      if (Platform.isMacOS) {
        final text = await _macClipboard.invokeMethod<String>('readText');
        return text?.trim() ?? '';
      }
    } catch (e) {
      debugPrint('Error reading clipboard: $e');
    }
    return '';
  }

  Future<void> _writeClipboard(String text) async {
    try {
      if (Platform.isMacOS) {
        await _macClipboard.invokeMethod('writeText', text);
      }
    } catch (e) {
      debugPrint('Error writing clipboard: $e');
    }
  }

  Future<void> _writeClipboardImage(
    Uint8List bytes,
    String mime,
  ) async {
    try {
      await _imageClipboard.invokeMethod('writeImage', {
        'bytes': bytes,
        'mime': mime,
      });
      // Writing the received image changes macOS's pasteboard token. Mark it
      // as already handled so the polling loop does not offer it back to the
      // Android device.
      _lastMacChangeToken = await _macChangeToken();
    } on PlatformException catch (error) {
      throw StateError(error.message ?? 'Could not write image to macOS clipboard.');
    }
  }

  Future<_PendingImage?> _readClipboardImage() async {
    try {
      final response = await _imageClipboard.invokeMethod<Map<dynamic, dynamic>>(
        'readImage',
        {'limitBytes': 20 * 1024 * 1024},
      );
      if (response == null) return null;
      if (response['tooLarge'] == true) {
        if (mounted) {
          setState(() {
            imageTransferStatus =
                'Image is still over 20 MB after compression; it was not offered.';
          });
        }
        return null;
      }
      final bytes = response['bytes'];
      if (bytes is! Uint8List) return null;
      return _PendingImage(
        bytes: bytes,
        mime: response['mime'] as String? ?? 'image/png',
        extension: response['extension'] as String? ?? 'png',
      );
    } on MissingPluginException {
      debugPrint(
        'Image clipboard channel is unavailable. Fully restart the macOS app '
        'after installing the native image-clipboard update.',
      );
      return null;
    } on PlatformException catch (error) {
      debugPrint('Could not read clipboard image: ${error.message}');
      return null;
    }
  }

  Future<void> startBonjoir() async {
    final bonsoircontent = BonsoirService(
      name: "clipboard sync ${Platform.localHostname}",
      type: '_clipboardsync._tcp',
      port: 8080,
      attributes: {
        'v': '2',
        'tls': '1',
        'fp': _identity!.fingerprint.replaceAll(':', ''),
      },
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
    if (_identity == null) {
      setState(() {
        statusMessage =
            'Secure identity is still preparing. Try again shortly.';
      });
      return;
    }
    try {
      await startBonjoir();
      final ip = InternetAddress.anyIPv4;
      const port = 8080;

      _clipboardPollTimer = Timer.periodic(const Duration(milliseconds: 100), (
        timer,
      ) async {
        if (_pollInFlight) return;
        _pollInFlight = true;
        try {
          final detectWatch = Stopwatch()..start();

          if (Platform.isMacOS) {
            final token = await _macChangeToken();
            if (token == _lastMacChangeToken) return;
            _lastMacChangeToken = token;
          }

          final image = await _readClipboardImage();
          if (image != null) {
            debugPrint(
              'Clipboard image detected: ${image.bytes.length} bytes (${image.mime})',
            );
            await _offerImage(image);
            return;
          }
          String current = _stripAllLatencyPrefixes(await _readClipboard());

          if (current.startsWith('CS1|')) {
            return;
          }

          if (current != _lastClipboard && current.isNotEmpty) {
            _lastClipboard = current;
            final message = jsonEncode({
              'type': 'clipboardUpdate',
              'text': current,
              'sentAt': DateTime.now().millisecondsSinceEpoch,
            });
            for (var client in _clients) {
              try {
                client.channel.sink.add(message);
              } catch (e) {
                debugPrint('Error sending to client: $e');
              }
            }
            detectWatch.stop();
            debugPrint(
              'LATENCY Mac→Android local_detect+read+send=${detectWatch.elapsedMilliseconds}ms '
              'clients=${_clients.length} text="$current"',
            );
          }
        } finally {
          _pollInFlight = false;
        }
      });

      var handler = webSocketHandler(_handleSecureClient);

      _server = await serve(
        handler,
        ip,
        port,
        securityContext: await _identity!.createSecurityContext(),
      );
      _newPairingCode();

      setState(() {
        isServerRunning = true;
        statusMessage = 'Secure sync running on $localIp:$port';
      });

      debugPrint('Secure WSS server started on $localIp:$port');
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
    _lastMacChangeToken = -1;
    _pairingCodeTimer?.cancel();
    _pairingCodeTimer = null;
    _pairingCode = null;
    for (final timer in _pendingImageTimers.values) {
      timer.cancel();
    }
    _pendingImageTimers.clear();
    _pendingImages.clear();
    _clearIncomingImageOffer();

    final clientsCopy = List<_ClientSession>.from(_clients);
    _clients.clear();

    for (var client in clientsCopy) {
      try {
        await client.channel.sink.close();
      } catch (e) {
        debugPrint('Error closing client: $e');
      }
    }

    await _server?.close(force: true);
    _server = null;

    await stopBonjoir();

    setState(() {
      isServerRunning = false;
      statusMessage = 'Stopped';
      connectedDevices = 0;
    });

    debugPrint('Server stopped. All connections closed.');
  }

  void _newPairingCode() {
    final code = (100000 + Random.secure().nextInt(900000)).toString();
    setState(() => _pairingCode = code);
    _pairingCodeTimer?.cancel();
    _pairingCodeTimer = Timer(const Duration(minutes: 5), () {
      if (mounted) setState(() => _pairingCode = null);
    });
  }

  void _send(_ClientSession client, Map<String, dynamic> message) {
    client.channel.sink.add(jsonEncode(message));
  }

  Future<void> _offerImage(_PendingImage image) async {
    if (_clients.isEmpty) {
      if (mounted) {
        setState(() {
          imageTransferStatus = 'Image detected, but no Android device is connected.';
        });
      }
      return;
    }
    final id = _randomToken();
    for (final timer in _pendingImageTimers.values) {
      timer.cancel();
    }
    _pendingImageTimers.clear();
    _pendingImages.clear();
    _pendingImages[id] = image;
    _pendingImageTimers[id] = Timer(const Duration(minutes: 2), () {
      _pendingImages.remove(id);
      _pendingImageTimers.remove(id);
      if (mounted) {
        setState(() => imageTransferStatus = 'Image offer expired after 2 minutes.');
      }
    });
    final hash = sha256.convert(image.bytes).toString();
    final message = jsonEncode({
      'type': 'imageOffer',
      'id': id,
      'name': 'clipboard-image.${image.extension}',
      'mime': image.mime,
      'size': image.bytes.length,
      'sha256': hash,
    });
    for (final client in _clients) {
      client.channel.sink.add(message);
    }
    if (mounted) {
      setState(() {
        imageTransferStatus =
            'Image offer sent to ${_clients.length} Android device(s). '
            'Waiting for Receive or Ignore.';
      });
    }
    debugPrint('Image offer sent: ${image.bytes.length} bytes (${image.mime})');
  }

  void _sendImage(_ClientSession client, String id) {
    final image = _pendingImages.remove(id);
    _pendingImageTimers.remove(id)?.cancel();
    if (image == null) return;
    const chunkSize = 48 * 1024;
    _send(client, {
      'type': 'imageStart',
      'id': id,
      'name': 'clipboard-image.${image.extension}',
      'mime': image.mime,
      'size': image.bytes.length,
      'sha256': sha256.convert(image.bytes).toString(),
    });
    for (var offset = 0; offset < image.bytes.length; offset += chunkSize) {
      final end = min(offset + chunkSize, image.bytes.length);
      _send(client, {
        'type': 'imageChunk',
        'id': id,
        'data': base64Encode(image.bytes.sublist(offset, end)),
      });
    }
    _send(client, {'type': 'imageEnd', 'id': id});
    if (mounted) {
      setState(() => imageTransferStatus = 'Image sent to Android.');
    }
  }

  void _clearIncomingImageOffer() {
    _incomingImageTimer?.cancel();
    _incomingImageTimer = null;
    _incomingImageOffer = null;
    _incomingImageBytes = null;
    _incomingImageAccepted = false;
  }

  void _respondToIncomingImage(
    _ClientSession client,
    bool accept, {
    String? reason,
  }) {
    final offer = _incomingImageOffer;
    if (offer == null) return;
    final message = <String, dynamic>{
      'type': accept ? 'imageAccept' : 'imageReject',
      'id': offer.id,
    };
    if (reason != null) message['reason'] = reason;
    _send(client, message);
    if (accept) {
      _incomingImageTimer?.cancel();
      _incomingImageTimer = null;
      _incomingImageAccepted = true;
    } else {
      _clearIncomingImageOffer();
    }
    if (mounted) {
      setState(() {
        imageTransferStatus = accept
            ? 'Receiving image from Android...'
            : reason == null
                ? 'Mac ignored the Android image offer.'
                : 'Image transfer cancelled: $reason';
      });
    }
  }

  void _showIncomingImageOffer(
    _ClientSession client,
    Map<String, dynamic> message,
  ) {
    final id = message['id'];
    final name = message['name'];
    final mime = message['mime'];
    final size = message['size'];
    final hash = message['sha256'];
    if (id is! String ||
        name is! String ||
        mime is! String ||
        size is! num ||
        hash is! String ||
        size > 20 * 1024 * 1024) {
      if (id is String) {
        _send(client, {
          'type': 'imageReject',
          'id': id,
          'reason': 'Invalid or oversized Android image offer',
        });
      }
      return;
    }
    if (_incomingImageOffer != null) {
      _respondToIncomingImage(
        client,
        false,
        reason: 'A newer Android image replaced this offer',
      );
    }
    final offer = _IncomingImageOffer(
      id: id,
      name: name,
      mime: mime,
      size: size.toInt(),
      sha256: hash,
    );
    _incomingImageOffer = offer;
    _incomingImageTimer = Timer(const Duration(minutes: 2), () {
      if (_incomingImageOffer?.id == offer.id) {
        _respondToIncomingImage(
          client,
          false,
          reason: 'Image offer expired after 2 minutes',
        );
      }
    });
    if (mounted) {
      setState(() {
        imageTransferStatus = 'Android copied an image. Waiting for Receive or Ignore.';
      });
    }
  }

  Future<void> _finishIncomingImage(
    _ClientSession client,
    String id,
  ) async {
    final offer = _incomingImageOffer;
    final bytes = _incomingImageBytes?.takeBytes();
    if (offer == null || offer.id != id || bytes == null) return;
    _clearIncomingImageOffer();
    if (sha256.convert(bytes).toString() != offer.sha256) {
      _send(client, {
        'type': 'imageReject',
        'id': id,
        'reason': 'Image integrity check failed on Mac',
      });
      if (mounted) {
        setState(() => imageTransferStatus = 'Image transfer failed: integrity check failed.');
      }
      return;
    }
    try {
      await _writeClipboardImage(bytes, offer.mime);
      if (mounted) {
        setState(() {
          imageTransferStatus =
              'Image received from Android and placed on the Mac clipboard.';
        });
      }
    } catch (error) {
      _send(client, {
        'type': 'imageReject',
        'id': id,
        'reason': 'Mac could not write the received image to its clipboard',
      });
      if (mounted) {
        setState(() => imageTransferStatus = 'Image transfer failed: $error');
      }
    }
  }

  void _handleSecureClient(WebSocketChannel channel) {
    final client = _ClientSession(channel);
    channel.stream.listen(
      (event) async {
        try {
          final message = jsonDecode(event.toString()) as Map<String, dynamic>;
          switch (message['type']) {
            case 'pairRequest':
              final deviceId = message['deviceId'];
              final code = message['pairCode'];
              debugPrint('Received Android pairing request.');
              if (deviceId is! String || code != _pairingCode) {
                debugPrint('Rejected Android pairing request: invalid or expired code.');
                _send(client, {
                  'type': 'error',
                  'message': 'Invalid pairing code',
                });
                await channel.sink.close();
                return;
              }
              final secret = _randomToken();
              await _pairingStore.saveSecret(deviceId, secret);
              debugPrint('Accepted Android pairing request.');
              _pairingCodeTimer?.cancel();
              if (mounted) setState(() => _pairingCode = null);
              _send(client, {'type': 'pairAccepted', 'pairingSecret': secret});
              return;

            case 'hello':
              final deviceId = message['deviceId'];
              if (deviceId is! String) {
                throw const FormatException('Missing device ID');
              }
              final secret = await _pairingStore.readSecret(deviceId);
              if (secret == null) {
                _send(client, {
                  'type': 'error',
                  'message': 'Device is not paired',
                });
                await channel.sink.close();
                return;
              }
              client.deviceId = deviceId;
              client.pairingSecret = secret;
              client.challenge = _randomToken();
              _send(client, {'type': 'challenge', 'value': client.challenge});
              return;

            case 'authenticate':
              final challenge = client.challenge;
              final secret = client.pairingSecret;
              if (secret == null ||
                  challenge == null ||
                  message['proof'] != _proof(secret, challenge)) {
                _send(client, {
                  'type': 'error',
                  'message': 'Authentication failed',
                });
                await channel.sink.close();
                return;
              }
              client.authenticated = true;
              _clients.add(client);
              if (mounted) setState(() => connectedDevices = _clients.length);
              _send(client, {'type': 'syncAccepted'});
              return;

            case 'clipboardUpdate':
              if (!client.authenticated || message['text'] is! String) {
                await channel.sink.close();
                return;
              }
              final text = message['text'] as String;
              await _writeClipboard(text);
              _lastClipboard = text;
              if (Platform.isMacOS) {
                _lastMacChangeToken = await _macChangeToken();
              }
              return;

            case 'imageAccept':
              if (client.authenticated && message['id'] is String) {
                _sendImage(client, message['id'] as String);
              }
              return;

            case 'imageReject':
              if (message['id'] is String) {
                final id = message['id'] as String;
                _pendingImages.remove(id);
                _pendingImageTimers.remove(id)?.cancel();
                final reason = message['reason'];
                if (mounted) {
                  setState(() {
                    imageTransferStatus = reason is String && reason.isNotEmpty
                        ? 'Image transfer cancelled: $reason'
                        : 'Android ignored the image offer.';
                  });
                }
              }
              return;

            case 'imageOffer':
              if (client.authenticated) {
                _showIncomingImageOffer(client, message);
              }
              return;

            case 'imageStart':
              final offer = _incomingImageOffer;
              if (client.authenticated &&
                  message['id'] is String &&
                  message['id'] == offer?.id &&
                  _incomingImageAccepted) {
                _incomingImageBytes = BytesBuilder(copy: false);
              }
              return;

            case 'imageChunk':
              final offer = _incomingImageOffer;
              if (client.authenticated &&
                  message['id'] is String &&
                  message['id'] == offer?.id &&
                  _incomingImageAccepted &&
                  _incomingImageBytes != null &&
                  message['data'] is String) {
                final chunk = base64Decode(message['data'] as String);
                if (_incomingImageBytes!.length + chunk.length >
                    20 * 1024 * 1024) {
                  _respondToIncomingImage(
                    client,
                    false,
                    reason: 'Image exceeded the 20 MB transfer limit',
                  );
                } else {
                  _incomingImageBytes!.add(chunk);
                }
              }
              return;

            case 'imageEnd':
              if (client.authenticated && message['id'] is String) {
                await _finishIncomingImage(client, message['id'] as String);
              }
              return;
          }
        } catch (error) {
          debugPrint('Secure client protocol error: $error');
          await channel.sink.close();
        }
      },
      onDone: () {
        _clients.remove(client);
        for (final timer in _pendingImageTimers.values) {
          timer.cancel();
        }
        _pendingImageTimers.clear();
        _pendingImages.clear();
        _clearIncomingImageOffer();
        if (mounted) setState(() => connectedDevices = _clients.length);
      },
      cancelOnError: true,
    );
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
                    _buildInfoRow('Port', '8080 (WSS)'),
                    const SizedBox(height: 8),
                    _buildInfoRow(
                      'Connected Devices',
                      connectedDevices.toString(),
                    ),
                    const SizedBox(height: 8),
                    _buildInfoRow('Image Transfer', imageTransferStatus),
                    if (_incomingImageOffer != null && !_incomingImageAccepted) ...[
                      const SizedBox(height: 16),
                      _buildIncomingImageOfferCard(),
                    ],
                    const SizedBox(height: 8),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Certificate Fingerprint:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      certificateFingerprint,
                      style: const TextStyle(fontFamily: 'monospace'),
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
                if (_pairingCode != null)
                  Column(
                    children: [
                      const Text(
                        'Android pairing code (expires in 5 minutes):',
                      ),
                      SelectableText(
                        _pairingCode!,
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 8,
                        ),
                      ),
                      TextButton(
                        onPressed: _newPairingCode,
                        child: const Text('Generate a new code'),
                      ),
                    ],
                  )
                else
                  OutlinedButton(
                    onPressed: _newPairingCode,
                    child: const Text('Generate pairing code'),
                  ),
                const SizedBox(height: 12),
                Text(
                  'If a code expires, tap Generate pairing code again. '
                  'The server stays running.\n'
                  'On Android: enter the code after selecting this Mac under Found Macs.\n'
                  'Look for: clipboard sync ${Platform.localHostname}',
                  style: const TextStyle(color: Colors.grey, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIncomingImageOfferCard() {
    final offer = _incomingImageOffer!;
    final client = _clients.cast<_ClientSession?>().firstWhere(
          (item) => item?.authenticated ?? false,
          orElse: () => null,
        );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Image copied on Android',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text('${offer.name} (${(offer.size / 1024).round()} KB)'),
          const Text('This offer expires in 2 minutes.'),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: client == null
                    ? null
                    : () => _respondToIncomingImage(client, false),
                child: const Text('Ignore'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: client == null
                    ? null
                    : () => _respondToIncomingImage(client, true),
                child: const Text('Receive'),
              ),
            ],
          ),
        ],
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

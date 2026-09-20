import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class PairingStore {
  File? _file;
  Map<String, String>? _secrets;

  Future<String?> readSecret(String deviceId) async {
    await _load();
    return _secrets![deviceId];
  }

  Future<void> saveSecret(String deviceId, String secret) async {
    await _load();
    _secrets![deviceId] = secret;
    await _save();
  }

  Future<void> forget(String deviceId) async {
    await _load();
    _secrets!.remove(deviceId);
    await _save();
  }

  Future<void> _load() async {
    if (_secrets != null) return;
    final supportDirectory = await getApplicationSupportDirectory();
    _file = File(
      '${supportDirectory.path}${Platform.pathSeparator}pairing-secrets.json',
    );
    if (!await _file!.exists()) {
      _secrets = {};
      return;
    }
    final decoded = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
    _secrets = decoded.map(
      (deviceId, secret) => MapEntry(deviceId, secret as String),
    );
  }

  Future<void> _save() async {
    final file = _file!;
    await file.writeAsString(jsonEncode(_secrets), flush: true);
    await Process.run('chmod', ['600', file.path]);
  }
}

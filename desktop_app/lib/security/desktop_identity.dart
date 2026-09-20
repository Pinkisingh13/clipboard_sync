import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Persistent TLS material for the macOS Clipboard Sync server.
///
/// The certificate is self-signed because this server is only reachable on the
/// local network. Android will later trust it by its SHA-256 fingerprint during
/// the pairing flow.
class DesktopIdentity {
  const DesktopIdentity._({
    required this.certificateFile,
    required this.privateKeyFile,
    required this.fingerprint,
  });

  final File certificateFile;
  final File privateKeyFile;
  final String fingerprint;

  Future<SecurityContext> createSecurityContext() async {
    return SecurityContext()
      ..useCertificateChain(certificateFile.path)
      ..usePrivateKey(privateKeyFile.path);
  }

  static Future<DesktopIdentity> loadOrCreate() async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('Secure desktop identity is currently macOS-only.');
    }

    final supportDirectory = await getApplicationSupportDirectory();
    final identityDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}identity',
    );
    await identityDirectory.create(recursive: true);

    final certificateFile = File(
      '${identityDirectory.path}${Platform.pathSeparator}server-cert.pem',
    );
    final privateKeyFile = File(
      '${identityDirectory.path}${Platform.pathSeparator}server-key.pem',
    );

    if (!await certificateFile.exists() || !await privateKeyFile.exists()) {
      final result = await Process.run('/usr/bin/openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:3072',
        '-sha256',
        '-nodes',
        '-keyout',
        privateKeyFile.path,
        '-out',
        certificateFile.path,
        '-days',
        '3650',
        '-subj',
        '/CN=Clipboard Sync',
      ]);

      if (result.exitCode != 0) {
        throw StateError(
          'Could not create the secure desktop identity: ${result.stderr}',
        );
      }

      final permissionResult = await Process.run('chmod', [
        '600',
        privateKeyFile.path,
      ]);
      if (permissionResult.exitCode != 0) {
        throw StateError(
          'Could not protect the private key: ${permissionResult.stderr}',
        );
      }
    }

    final certificateDer = await Process.run('/usr/bin/openssl', [
      'x509',
      '-in',
      certificateFile.path,
      '-outform',
      'DER',
    ], stdoutEncoding: null);
    if (certificateDer.exitCode != 0) {
      throw StateError(
        'Could not read the desktop certificate: ${certificateDer.stderr}',
      );
    }

    final hash = sha256.convert(certificateDer.stdout as List<int>).toString();
    final fingerprint = hash
        .toUpperCase()
        .replaceAllMapped(RegExp(r'.{2}'), (match) => '${match.group(0)}:')
        .replaceFirst(RegExp(r':$'), '');

    return DesktopIdentity._(
      certificateFile: certificateFile,
      privateKeyFile: privateKeyFile,
      fingerprint: fingerprint,
    );
  }
}

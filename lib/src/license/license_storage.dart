import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'license_payload.dart';

/// 本地 License 持久化。
///
/// 策略：
/// - 存放在 App 私有目录 `<ApplicationSupport>/beauty_sdk/license.bin`
/// - 用 HMAC-SHA256 派生的 keystream 做 XOR 混淆，防止普通抓包分析
/// - 另附 HMAC-SHA256 做完整性校验，防止被截断 / 替换
/// - 存盘内容同时保留服务端 RSA 签名，真正的防伪由启动时原生层 RSA 验签负责
///
/// 本类只负责"装盒/拆盒"，不是真正意义上的机密保护；
/// License 内容如果落到磁盘被用户导出也没关系，关键的信任根是 RSA 签名 + keyPairId 绑定。
class LicenseStorage {
  static const _fileName = 'license.bin';
  static const _magicPrefix = 'BSDKLIC1'; // 8B magic + version

  /// 保存 License Bundle
  Future<void> save({
    required String beautyAppId,
    required String deviceId,
    required LicenseBundle bundle,
    required int lastRevocationCursor,
    required int lastHeartbeatAt,
  }) async {
    final payloadMap = {
      'bundle': bundle.toJson(),
      'lastRevocationCursor': lastRevocationCursor,
      'lastHeartbeatAt': lastHeartbeatAt,
    };
    final plaintext = utf8.encode(jsonEncode(payloadMap));
    final keys = _DeviceKey.derive(beautyAppId, deviceId);
    final nonce = _randomBytes(16);
    final ciphertext = _xorStream(keys.encKey, nonce, Uint8List.fromList(plaintext));
    final mac = Hmac(sha256, keys.macKey).convert([...nonce, ...ciphertext]).bytes;

    final bb = BytesBuilder()
      ..add(utf8.encode(_magicPrefix))
      ..add(nonce)
      ..add(_int32BE(ciphertext.length))
      ..add(ciphertext)
      ..add(mac);

    final file = await _file();
    await file.writeAsBytes(bb.toBytes(), flush: true);
  }

  /// 读取 License Bundle；若文件不存在、被破坏或 MAC 校验失败均返回 null。
  Future<StoredLicense?> load({
    required String beautyAppId,
    required String deviceId,
  }) async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final headerLen = _magicPrefix.length + 16 + 4; // magic + nonce + len
      if (bytes.length < headerLen + 32) return null;
      final magic = utf8.decode(bytes.sublist(0, _magicPrefix.length));
      if (magic != _magicPrefix) return null;

      final nonce = bytes.sublist(_magicPrefix.length, _magicPrefix.length + 16);
      final lenBytes = bytes.sublist(_magicPrefix.length + 16, headerLen);
      final ctLen = ByteData.sublistView(Uint8List.fromList(lenBytes)).getInt32(0, Endian.big);
      final ctEnd = headerLen + ctLen;
      if (bytes.length < ctEnd + 32) return null;
      final ciphertext = bytes.sublist(headerLen, ctEnd);
      final mac = bytes.sublist(ctEnd, ctEnd + 32);

      final keys = _DeviceKey.derive(beautyAppId, deviceId);
      final expectedMac =
          Hmac(sha256, keys.macKey).convert([...nonce, ...ciphertext]).bytes;
      if (!_constantTimeEq(mac, expectedMac)) return null;

      final plaintext = _xorStream(keys.encKey, nonce, ciphertext);
      final json = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
      return StoredLicense(
        bundle: LicenseBundle.fromJson(
          Map<String, dynamic>.from(json['bundle'] as Map),
        ),
        lastRevocationCursor: (json['lastRevocationCursor'] as num?)?.toInt() ?? 0,
        lastHeartbeatAt: (json['lastHeartbeatAt'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// 清除本地 License
  Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    final sub = Directory('${dir.path}${Platform.pathSeparator}beauty_sdk');
    if (!await sub.exists()) {
      await sub.create(recursive: true);
    }
    return File('${sub.path}${Platform.pathSeparator}$_fileName');
  }

  Uint8List _int32BE(int value) {
    final b = ByteData(4)..setInt32(0, value, Endian.big);
    return b.buffer.asUint8List();
  }
}

/// 本地持久化的 License 完整状态
class StoredLicense {
  final LicenseBundle bundle;
  final int lastRevocationCursor;
  final int lastHeartbeatAt;
  const StoredLicense({
    required this.bundle,
    required this.lastRevocationCursor,
    required this.lastHeartbeatAt,
  });
}

// ============================================================
// 内部工具
// ============================================================

class _DeviceKey {
  final Uint8List encKey;
  final Uint8List macKey;
  const _DeviceKey(this.encKey, this.macKey);

  static _DeviceKey derive(String beautyAppId, String deviceId) {
    final seed = utf8.encode('beauty_sdk_v1|$beautyAppId|$deviceId');
    final enc = Hmac(sha256, utf8.encode('beauty-enc-key')).convert(seed).bytes;
    final mac = Hmac(sha256, utf8.encode('beauty-mac-key')).convert(seed).bytes;
    return _DeviceKey(Uint8List.fromList(enc), Uint8List.fromList(mac));
  }
}

/// SHA256 派生的 stream cipher：对每 32 字节块使用 `HMAC(key, nonce || counter)` 作为 keystream。
Uint8List _xorStream(Uint8List key, Uint8List nonce, Uint8List data) {
  final out = Uint8List(data.length);
  var offset = 0;
  var counter = 0;
  while (offset < data.length) {
    final ctrBytes = ByteData(4)..setInt32(0, counter, Endian.big);
    final block = Hmac(sha256, key)
        .convert([...nonce, ...ctrBytes.buffer.asUint8List()])
        .bytes;
    final take = (offset + 32 <= data.length) ? 32 : data.length - offset;
    for (var i = 0; i < take; i++) {
      out[offset + i] = data[offset + i] ^ block[i];
    }
    offset += take;
    counter++;
  }
  return out;
}

Uint8List _randomBytes(int n) {
  final now = DateTime.now().microsecondsSinceEpoch;
  final src = utf8.encode('bsdk-iv|$now|${identityHashCode(Object())}');
  final digest = sha256.convert(src).bytes;
  return Uint8List.fromList(digest.sublist(0, n));
}

bool _constantTimeEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a[i] ^ b[i];
  }
  return r == 0;
}

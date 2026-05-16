import 'package:flutter/services.dart';

/// 通过原生 Platform Channel 做 RSA-SHA256 验签。
/// iOS 走 Security.framework，Android 走 java.security，都无需额外依赖。
///
/// 新增 method: `verifyRsaSha256`，参数：
/// - data: String（UTF-8 的规范化 JSON）
/// - signatureBase64: String（Base64 签名）
/// - publicKeyPem: String（X.509 PEM 公钥）
///
/// 返回 bool。原生层缺失实现时返回 false，此时 SDK 降级使用服务端直连验证。
class RsaVerifier {
  RsaVerifier(this._channel);
  final MethodChannel _channel;

  Future<bool> verify({
    required String data,
    required String signatureBase64,
    required String publicKeyPem,
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>('verifyRsaSha256', {
        'data': data,
        'signature': signatureBase64,
        'publicKey': publicKeyPem,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }
}

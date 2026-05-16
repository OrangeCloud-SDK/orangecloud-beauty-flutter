/// Result of a Beauty SDK operation.
class BeautyResult {
  /// Result code: 0=success, 4001=expired, 4002=disabled, 4003=device limit, 4004=re-verify failed
  final int code;

  /// Human-readable message
  final String message;

  const BeautyResult({required this.code, required this.message});

  bool get isSuccess => code == 0;

  factory BeautyResult.success([String message = 'OK']) {
    return BeautyResult(code: 0, message: message);
  }

  factory BeautyResult.fromMap(Map<String, dynamic> map) {
    return BeautyResult(
      code: map['code'] as int? ?? -1,
      message: map['message'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {'code': code, 'message': message};
  }
}

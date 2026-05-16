/// Represents an error from the Beauty SDK.
class BeautyError {
  /// Error code
  final int code;

  /// Error message (localized)
  final String message;

  /// Optional details
  final String? details;

  const BeautyError({
    required this.code,
    required this.message,
    this.details,
  });

  factory BeautyError.fromMap(Map<String, dynamic> map) {
    return BeautyError(
      code: map['code'] as int? ?? -1,
      message: map['message'] as String? ?? 'Unknown error',
      details: map['details'] as String?,
    );
  }

  /// Error codes
  static const int expired = 4001;
  static const int disabled = 4002;
  static const int deviceLimit = 4003;
  static const int reVerifyFailed = 4004;
  static const int revoked = 4005;
  static const int packageMismatch = 4006;
  static const int authFailed = 4010;
  static const int tokenExpired = 4011;
  static const int tokenInvalid = 4012;
  static const int appIdInvalid = 4013;
  static const int featureNotLicensed = 4050;
  static const int sessionEnded = -1;

  @override
  String toString() => 'BeautyError($code: $message)';
}

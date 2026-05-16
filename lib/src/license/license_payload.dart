import 'dart:convert';

/// 与服务端 `LicensePayload.cs` 一一对应的数据负载。
///
/// 字段顺序 / 名称 **必须严格按字典序 + 小写驼峰**，否则与服务端签名无法对齐。
class LicensePayload {
  final int licenseId;
  final int keyPairId;
  final String beautyAppId;
  final String deviceId;
  final String packageName;
  final String platformType;
  final int features;
  final int issuedAt;
  final int expireAt;
  final int offlineDays;
  final int heartbeatHours;
  final int notifyBeforeDays;
  final String tenantName;

  const LicensePayload({
    required this.licenseId,
    required this.keyPairId,
    required this.beautyAppId,
    required this.deviceId,
    required this.packageName,
    required this.platformType,
    required this.features,
    required this.issuedAt,
    required this.expireAt,
    required this.offlineDays,
    required this.heartbeatHours,
    required this.notifyBeforeDays,
    required this.tenantName,
  });

  factory LicensePayload.fromJson(Map<String, dynamic> json) => LicensePayload(
    licenseId:        (json['licenseId']        as num?)?.toInt() ?? 0,
    keyPairId:        (json['keyPairId']        as num?)?.toInt() ?? 0,
    beautyAppId:      json['beautyAppId']?.toString() ?? '',
    deviceId:         json['deviceId']?.toString() ?? '',
    packageName:      json['packageName']?.toString() ?? '',
    platformType:     json['platformType']?.toString() ?? '',
    features:         (json['features']         as num?)?.toInt() ?? 0,
    issuedAt:         (json['issuedAt']         as num?)?.toInt() ?? 0,
    expireAt:         (json['expireAt']         as num?)?.toInt() ?? 0,
    offlineDays:      (json['offlineDays']      as num?)?.toInt() ?? 0,
    heartbeatHours:   (json['heartbeatHours']   as num?)?.toInt() ?? 0,
    notifyBeforeDays: (json['notifyBeforeDays'] as num?)?.toInt() ?? 0,
    tenantName:       json['tenantName']?.toString() ?? '',
  );

  Map<String, dynamic> toJson() => {
    'licenseId':        licenseId,
    'keyPairId':        keyPairId,
    'beautyAppId':      beautyAppId,
    'deviceId':         deviceId,
    'packageName':      packageName,
    'platformType':     platformType,
    'features':         features,
    'issuedAt':         issuedAt,
    'expireAt':         expireAt,
    'offlineDays':      offlineDays,
    'heartbeatHours':   heartbeatHours,
    'notifyBeforeDays': notifyBeforeDays,
    'tenantName':       tenantName,
  };

  /// 生成与服务端完全一致的规范化 JSON（按字段名字典序、紧凑无空白）。
  ///
  /// 必须与服务端 `LicenseSigner.Canonicalize` 生成的字符串字节级一致，
  /// 否则 RSA 签名无法通过。
  String canonicalize() {
    final sorted = <String, dynamic>{
      'beautyAppId':      beautyAppId,
      'deviceId':         deviceId,
      'expireAt':         expireAt,
      'features':         features,
      'heartbeatHours':   heartbeatHours,
      'issuedAt':         issuedAt,
      'keyPairId':        keyPairId,
      'licenseId':        licenseId,
      'notifyBeforeDays': notifyBeforeDays,
      'offlineDays':      offlineDays,
      'packageName':      packageName,
      'platformType':     platformType,
      'tenantName':       tenantName,
    };
    return jsonEncode(sorted);
  }

  /// 当前剩余秒数（可能为负）
  int remainingSeconds([int? nowSeconds]) {
    final now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return expireAt - now;
  }

  /// 距离到期的天数（向下取整，可能为负）
  int remainingDays([int? nowSeconds]) {
    return remainingSeconds(nowSeconds) ~/ 86400;
  }

  bool isExpired([int? nowSeconds]) => remainingSeconds(nowSeconds) <= 0;
}

/// 服务端 `/BeautyClient/Activate` 返回数据包
class LicenseBundle {
  final LicensePayload payload;
  final String signature;
  final String publicKey;

  const LicenseBundle({
    required this.payload,
    required this.signature,
    required this.publicKey,
  });

  factory LicenseBundle.fromJson(Map<String, dynamic> json) => LicenseBundle(
    payload:   LicensePayload.fromJson(
      Map<String, dynamic>.from(json['payload'] as Map),
    ),
    signature: json['signature']?.toString() ?? '',
    publicKey: json['publicKey']?.toString() ?? '',
  );

  Map<String, dynamic> toJson() => {
    'payload':   payload.toJson(),
    'signature': signature,
    'publicKey': publicKey,
  };
}

/// 吊销名单条目
class RevocationEntry {
  final String beautyAppId;
  final String deviceId;
  final int revokedAt;
  final String reason;
  const RevocationEntry({
    required this.beautyAppId,
    required this.deviceId,
    required this.revokedAt,
    required this.reason,
  });

  factory RevocationEntry.fromJson(Map<String, dynamic> json) => RevocationEntry(
    beautyAppId: json['beautyAppId']?.toString() ?? '',
    deviceId:    json['deviceId']?.toString() ?? '',
    revokedAt:   (json['revokedAt'] as num?)?.toInt() ?? 0,
    reason:      json['reason']?.toString() ?? '',
  );
}

/// 心跳响应
class HeartbeatResult {
  final int status;
  final int serverTime;
  final int expireAt;
  final int features;
  const HeartbeatResult({
    required this.status,
    required this.serverTime,
    required this.expireAt,
    required this.features,
  });

  factory HeartbeatResult.fromJson(Map<String, dynamic> json) => HeartbeatResult(
    status:     (json['status']     as num?)?.toInt() ?? -1,
    serverTime: (json['serverTime'] as num?)?.toInt() ?? 0,
    expireAt:   (json['expireAt']   as num?)?.toInt() ?? 0,
    features:   (json['features']   as num?)?.toInt() ?? 0,
  );
}

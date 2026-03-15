import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:intl/intl.dart';
import 'package:flutter/foundation.dart';

class S3Signer {
  /// S3 专用 URI 编码：符合 RFC 3986，不对 ~ 进行编码，将空格正确编码为 %20
  static String uriEncode(String input) {
    return Uri.encodeComponent(input).replaceAll('%7E', '~');
  }

  static Map<String, String> generateV4Headers({
    required String method,
    required String host,
    required String path,
    Map<String, String>? queryParams,
    Map<String, String>? extraHeaders, // [新增]: 用于支持 x-amz-copy-source 等附加头
    required String ak,
    required String sk,
    String? payloadHash, 
    List<int>? payloadBytes, 
  }) {
    final now = DateTime.now().toUtc();
    final amzDate = DateFormat("yyyyMMdd'T'HHmmss'Z'").format(now);
    final dateStamp = DateFormat("yyyyMMdd").format(now);
    const region = 'us-east-1'; 
    const service = 's3';

    final actualPayloadHash = payloadHash ?? 
        (payloadBytes != null 
            ? sha256.convert(payloadBytes).toString() 
            : sha256.convert(utf8.encode('')).toString());

    final credential = '$ak/$dateStamp/$region/$service/aws4_request';

    // [核心修改]: 动态拼接需要被签名的 Headers
    Map<String, String> canonicalHeadersMap = {
      'host': host,
      'x-amz-content-sha256': actualPayloadHash,
      'x-amz-date': amzDate,
    };
    if (extraHeaders != null) {
      extraHeaders.forEach((key, value) {
        canonicalHeadersMap[key.toLowerCase()] = value.trim();
      });
    }

    final sortedHeaderKeys = canonicalHeadersMap.keys.toList()..sort();
    final canonicalHeadersStr = sortedHeaderKeys.map((k) => '$k:${canonicalHeadersMap[k]}').join('\n') + '\n';
    final signedHeadersStr = sortedHeaderKeys.join(';');

    String canonicalQueryString = '';
    if (queryParams != null && queryParams.isNotEmpty) {
      final keys = queryParams.keys.toList()..sort();
      canonicalQueryString = keys.map((k) => '${uriEncode(k)}=${uriEncode(queryParams[k]!)}').join('&');
    }

    // 3. 构建 Canonical Request
    final canonicalRequest =[
      method.toUpperCase(),
      path,
      canonicalQueryString, 
      canonicalHeadersStr, // 替换这里
      signedHeadersStr,    // 替换这里
      actualPayloadHash
    ].join('\n');

    // ... 下方计算 stringToSign 和 signature 的逻辑保持不变 ...
    final stringToSign =[
      'AWS4-HMAC-SHA256', amzDate, '$dateStamp/$region/$service/aws4_request',
      sha256.convert(utf8.encode(canonicalRequest)).toString()
    ].join('\n');

    final kSecret = utf8.encode('AWS4$sk');
    final kDate = Hmac(sha256, kSecret).convert(utf8.encode(dateStamp)).bytes;
    final kRegion = Hmac(sha256, kDate).convert(utf8.encode(region)).bytes;
    final kService = Hmac(sha256, kRegion).convert(utf8.encode(service)).bytes;
    final kSigning = Hmac(sha256, kService).convert(utf8.encode('aws4_request')).bytes;
    final signature = Hmac(sha256, kSigning).convert(utf8.encode(stringToSign)).toString();

    // 组装最终请求头返回
    final headers = {
      'host': host,
      'x-amz-date': amzDate,
      'x-amz-content-sha256': actualPayloadHash,
      if (extraHeaders != null) ...extraHeaders, // 注入附加头
      'Authorization': 'AWS4-HMAC-SHA256 Credential=$credential, SignedHeaders=$signedHeadersStr, Signature=$signature'
    };

    return headers;
  }
}
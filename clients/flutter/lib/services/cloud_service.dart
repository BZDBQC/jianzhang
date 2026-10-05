import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

final class CloudFailure implements Exception {
  const CloudFailure(this.message, this.status, [this.code = '']);
  final String message;
  final int status;
  final String code;
  @override
  String toString() => message;
}

final class CloudUser {
  const CloudUser({
    required this.userId,
    required this.name,
    required this.kind,
  });
  final String userId;
  final String name;
  final String kind;
  factory CloudUser.fromJson(Map<String, dynamic> json) {
    if (json['userId'] is! String ||
        (json['userId'] as String).isEmpty ||
        json['name'] is! String ||
        json['kind'] != 'phone') {
      throw const CloudFailure('云服务返回了无效的账号', 502);
    }
    return CloudUser(
      userId: json['userId'] as String,
      name: json['name'] as String,
      kind: json['kind'] as String,
    );
  }
}

final class CloudSession {
  const CloudSession({required this.user, required this.expires});
  final CloudUser user;
  final int expires;
}

final class SmsChallenge {
  const SmsChallenge({
    required this.challengeId,
    required this.retryAfter,
    required this.expiresIn,
  });
  final String challengeId;
  final int retryAfter;
  final int expiresIn;
}

final class CloudSnapshot {
  const CloudSnapshot({
    required this.ledger,
    required this.revision,
    required this.user,
  });
  final Map<String, dynamic> ledger;
  final int revision;
  final CloudUser user;
}

/// Stores the bearer token only in the platform credential store. Local ledger
/// availability is independent of every method in this class.
class CloudService {
  CloudService({http.Client? client, SessionStore? sessionStore, Uri? baseUri})
    : _client = client ?? http.Client(),
      _storage = sessionStore ?? const CredentialSessionStore(),
      _base =
          baseUri ??
          Uri.parse(
            'https://jianzhang-ledger-rm.raowx9744.chatgpt.site/api/native/v1/',
          );
  static const _key = 'jianzhang.native.session.v1';
  static const cloudBytes = 8000000;
  final http.Client _client;
  final SessionStore _storage;
  final Uri _base;
  String? _token;
  int _expires = 0;

  Future<void> _loadToken() async {
    if (_token != null) return;
    final raw = await _storage.read(_key);
    if (raw == null) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final token = json['token'];
      final expires = json['expires'];
      if (token is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(token) ||
          expires is! int ||
          expires <= DateTime.now().millisecondsSinceEpoch ~/ 1000) {
        await _storage.delete(_key);
        return;
      }
      _token = token;
      _expires = expires;
    } on FormatException {
      await _storage.delete(_key);
    } on TypeError {
      await _storage.delete(_key);
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = false,
    List<int>? encodedBody,
  }) async {
    final uri = _base.resolve(path);
    if (uri.scheme != 'https' &&
        !(uri.scheme == 'http' &&
            ['localhost', '127.0.0.1', '::1'].contains(uri.host))) {
      throw const CloudFailure('云同步需要安全连接', 403, 'TRANSPORT');
    }
    if (authenticated) {
      await _loadToken();
      if (_token == null) throw const CloudFailure('请先登录云端账号', 401);
    }
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    if (authenticated) request.headers['Authorization'] = 'Bearer $_token';
    if (body != null || encodedBody != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.bodyBytes = encodedBody ?? utf8.encode(jsonEncode(body));
    }
    try {
      return await (() async {
        final response = await _client.send(request);
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > cloudBytes + 100000) {
            throw const CloudFailure('云服务返回的数据过大，未修改本机账本', 502);
          }
          bytes.addAll(chunk);
        }
        Map<String, dynamic> json = {};
        try {
          json = await compute(_decodeResponse, bytes);
        } on Object {
          if (response.statusCode >= 200 && response.statusCode < 300) {
            throw const CloudFailure('云服务返回格式异常，本机账本未改变', 502);
          }
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          if (response.statusCode == 401) {
            _token = null;
            _expires = 0;
            await _storage.delete(_key);
          }
          throw CloudFailure(
            json['error'] is String
                ? json['error'] as String
                : '云服务暂时不可用，请继续本机记账',
            response.statusCode,
            json['code'] is String ? json['code'] as String : '',
          );
        }
        return json;
      })().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const CloudFailure('连接超时，本机账本未改变，请稍后重试', 0, 'TIMEOUT');
    } on http.ClientException {
      throw const CloudFailure('无法连接云端，本机账本未改变', 0, 'NETWORK');
    }
  }

  Future<CloudSession?> session() async {
    await _loadToken();
    if (_token == null) return null;
    final json = await _request('GET', 'auth/session', authenticated: true);
    if (json['user'] == null) {
      _token = null;
      _expires = 0;
      await _storage.delete(_key);
      return null;
    }
    return CloudSession(
      user: CloudUser.fromJson(json['user'] as Map<String, dynamic>),
      expires: _expires,
    );
  }

  Future<SmsChallenge> sendCode(String phone) async {
    final json = await _request('POST', 'auth/send', body: {'phone': phone});
    if (json['challengeId'] is! String ||
        json['retryAfter'] is! int ||
        json['expiresIn'] is! int) {
      throw const CloudFailure('验证码服务返回格式异常', 502);
    }
    return SmsChallenge(
      challengeId: json['challengeId'] as String,
      retryAfter: json['retryAfter'] as int,
      expiresIn: json['expiresIn'] as int,
    );
  }

  Future<CloudSession> verify(String challengeId, String code) async {
    final json = await _request(
      'POST',
      'auth/verify',
      body: {'challengeId': challengeId, 'code': code},
    );
    final token = json['token'], expires = json['expires'];
    if (token is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(token) ||
        expires is! int ||
        expires <= DateTime.now().millisecondsSinceEpoch ~/ 1000) {
      throw const CloudFailure('登录服务未建立有效会话', 502);
    }
    final user = CloudUser.fromJson(json['user'] as Map<String, dynamic>);
    await _storage.write(
      _key,
      jsonEncode({'token': token, 'expires': expires}),
    );
    _token = token;
    _expires = expires;
    return CloudSession(user: user, expires: expires);
  }

  Future<void> logout() async {
    try {
      await _loadToken();
      if (_token != null) {
        await _request('POST', 'auth/logout', body: {}, authenticated: true);
      }
    } finally {
      _token = null;
      _expires = 0;
      await _storage.delete(_key);
    }
  }

  Future<CloudSnapshot> download() async {
    final json = await _request('GET', 'ledger', authenticated: true);
    if (json['ledger'] is! Map<String, dynamic> ||
        json['revision'] is! int ||
        (json['revision'] as int) < 0) {
      throw const CloudFailure('云端账本格式异常', 502);
    }
    return CloudSnapshot(
      ledger: json['ledger'] as Map<String, dynamic>,
      revision: json['revision'] as int,
      user: CloudUser.fromJson(json['user'] as Map<String, dynamic>),
    );
  }

  Future<int> upload(
    Map<String, dynamic> ledger, {
    required int revision,
    required String expectedUserId,
  }) async {
    final transactions = ledger['transactions'];
    if (transactions is! List || transactions.length > 20000) {
      throw const CloudFailure('云端最多支持 2 万笔。本机账本仍可使用和导出。', 400, 'CLOUD_LIMIT');
    }
    final bytes = await compute(_encodeRequest, {
      'ledger': ledger,
      'revision': revision,
      'expectedUserId': expectedUserId,
    });
    if (bytes.length > cloudBytes) {
      throw const CloudFailure(
        '云端上传不能超过 8 MB。本机账本仍可使用和导出。',
        400,
        'CLOUD_LIMIT',
      );
    }
    final json = await _request(
      'PUT',
      'ledger',
      encodedBody: bytes,
      authenticated: true,
    );
    if (json['revision'] is! int || json['revision'] != revision + 1) {
      throw const CloudFailure('云端返回版本异常，请重新读取后核对；本机账本已保留', 502);
    }
    return json['revision'] as int;
  }

  void close() => _client.close();
}

Map<String, dynamic> _decodeResponse(List<int> bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
List<int> _encodeRequest(Map<String, dynamic> value) =>
    utf8.encode(jsonEncode(value));

abstract interface class SessionStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class CredentialSessionStore implements SessionStore {
  const CredentialSessionStore();
  static const _storage = FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _guard(() => _storage.read(key: key));
  @override
  Future<void> write(String key, String value) =>
      _guard(() => _storage.write(key: key, value: value));
  @override
  Future<void> delete(String key) => _guard(() => _storage.delete(key: key));
  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on Object {
      throw const CloudFailure(
        '系统安全存储暂不可用，云登录未完成；可继续本机记账',
        503,
        'CREDENTIAL_STORAGE',
      );
    }
  }
}

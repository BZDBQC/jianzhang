import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jianzhang/services/cloud_service.dart';

class MemoryStore implements SessionStore {
  final values = <String, String>{};
  bool failWrite = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('credential store unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

Map<String, dynamic> loginBody() => {
  'token': 'a' * 64,
  'expires': 4102444800,
  'user': {'userId': 'phone:fixture', 'name': '138****8000', 'kind': 'phone'},
};
http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'local availability: blank credentials do not issue network requests',
    () async {
      var calls = 0;
      final cloud = CloudService(
        sessionStore: MemoryStore(),
        client: MockClient((request) async {
          calls++;
          throw StateError('unexpected network');
        }),
      );
      expect(await cloud.session(), isNull);
      expect(calls, 0);
      cloud.close();
    },
  );
  test(
    'login stores opaque credential, does not upload, and sends explicit bearer without cookies',
    () async {
      final calls = <http.Request>[];
      final store = MemoryStore();
      final cloud = CloudService(
        sessionStore: store,
        client: MockClient((request) async {
          calls.add(request);
          return request.url.path.endsWith('verify')
              ? jsonResponse(loginBody())
              : jsonResponse({'user': loginBody()['user'], 'configured': true});
        }),
      );
      final logged = await cloud.verify('fixture', '001234');
      expect(logged.user.userId, 'phone:fixture');
      expect(calls.length, 1);
      expect(calls.single.url.path, endsWith('/auth/verify'));
      expect(store.values.values.single, contains('a' * 64));
      await cloud.session();
      expect(calls.last.headers['Authorization'], 'Bearer ${'a' * 64}');
      expect(
        calls.last.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('cookie')),
      );
      expect(
        calls.last.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('origin')),
      );
      cloud.close();
    },
  );
  test('unconfigured SMS surfaces 503 and never creates a session', () async {
    final store = MemoryStore();
    final cloud = CloudService(
      sessionStore: store,
      client: MockClient(
        (_) async => jsonResponse({
          'error': '手机号登录尚未配置短信服务',
          'code': 'SMS_NOT_CONFIGURED',
        }, 503),
      ),
    );
    await expectLater(
      cloud.sendCode('13800138000'),
      throwsA(
        isA<CloudFailure>()
            .having((e) => e.status, 'status', 503)
            .having((e) => e.code, 'code', 'SMS_NOT_CONFIGURED'),
      ),
    );
    expect(store.values, isEmpty);
    cloud.close();
  });
  test('cloud limits count full UTF-8 envelope before any request', () async {
    var calls = 0;
    final cloud = CloudService(
      sessionStore: MemoryStore(),
      client: MockClient((_) async {
        calls++;
        return jsonResponse({'revision': 1});
      }),
    );
    for (final ledger in [
      {
        'transactions': List.generate(20001, (i) => {'id': '$i'}),
      },
      {'transactions': [], 'notes': '中文😀' * 800001},
    ]) {
      await expectLater(
        cloud.upload(ledger, revision: 0, expectedUserId: 'phone:fixture'),
        throwsA(
          isA<CloudFailure>().having((e) => e.code, 'code', 'CLOUD_LIMIT'),
        ),
      );
    }
    expect(calls, 0);
    cloud.close();
  });
  test(
    '409/503/401 do not mutate ledger; only 401 expires credential',
    () async {
      final store = MemoryStore();
      var status = 200;
      final cloud = CloudService(
        sessionStore: store,
        client: MockClient((request) async {
          if (request.url.path.endsWith('verify')) {
            return jsonResponse(loginBody());
          }
          return jsonResponse({'error': 'simulated failure'}, status);
        }),
      );
      await cloud.verify('fixture', '001234');
      final ledger = <String, dynamic>{'transactions': [], 'note': '本机内容😀'};
      final before = jsonEncode(ledger);
      for (final code in [409, 503, 401]) {
        status = code;
        await expectLater(
          cloud.upload(ledger, revision: 0, expectedUserId: 'phone:fixture'),
          throwsA(isA<CloudFailure>().having((e) => e.status, 'status', code)),
        );
        expect(jsonEncode(ledger), before);
        expect(store.values.isEmpty, code == 401);
      }
      cloud.close();
    },
  );
  test('failed credential write does not report a successful login', () async {
    final store = MemoryStore()..failWrite = true;
    final cloud = CloudService(
      sessionStore: store,
      client: MockClient((_) async => jsonResponse(loginBody())),
    );
    await expectLater(cloud.verify('fixture', '001234'), throwsStateError);
    expect(store.values, isEmpty);
    cloud.close();
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/message_plaintext_store.dart';
import 'package:samay/core/services/storage_service.dart';

/// In-memory FlutterSecureStorage stand-in (mocktail) — no platform channels.
class _MockSecureStorage extends Mock implements FlutterSecureStorage {
  String? storedKey;

  void setup() {
    when(() => read(key: any(named: 'key'))).thenAnswer((_) async => storedKey);
    when(
      () => write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((invocation) async {
      storedKey = invocation.namedArguments[#value] as String?;
    });
  }
}

void main() {
  late Directory tempDir;
  late _MockSecureStorage secureStorage;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('plaintext_store_test_');
    secureStorage = _MockSecureStorage()..setup();
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// A store over an initialized (boxes open) HiveService.
  Future<HiveMessagePlaintextStore> openStore() async {
    final service = HiveService(secureStorage: secureStorage, hive: Hive);
    await service.init(initializeFlutter: false);
    return HiveMessagePlaintextStore(service);
  }

  group('MessagePlaintextStore (encrypted Hive — SQLCipher-equivalent)', () {
    test('cache/get roundtrip is scoped per (chat, message)', () async {
      final store = await openStore();

      await store.cache('chat-1', 'm-1', 'hola');
      await store.cache('chat-1', 'm-2', 'mundo');
      await store.cache('chat-2', 'm-1', 'otro chat');

      expect(await store.get('chat-1', 'm-1'), 'hola');
      expect(await store.get('chat-1', 'm-2'), 'mundo');
      expect(await store.get('chat-2', 'm-1'), 'otro chat');
      expect(await store.get('chat-1', 'm-9'), isNull);
      expect(await store.get('chat-3', 'm-1'), isNull);
    });

    test('delete removes only the addressed entry', () async {
      final store = await openStore();
      await store.cache('chat-1', 'm-1', 'a');
      await store.cache('chat-1', 'm-2', 'b');
      await store.cache('chat-2', 'm-1', 'c');

      await store.delete('chat-1', 'm-1');

      expect(await store.get('chat-1', 'm-1'), isNull);
      expect(await store.get('chat-1', 'm-2'), 'b');
      expect(await store.get('chat-2', 'm-1'), 'c');
    });

    test('prune keeps the NEWEST maxPerChat entries per chat (by cache time)',
        () async {
      final store = await openStore();
      for (var i = 0; i < 5; i++) {
        await store.cache('chat-1', 'm-$i', 'v$i');
      }

      await store.prune('chat-1', 2);

      expect(await store.get('chat-1', 'm-0'), isNull);
      expect(await store.get('chat-1', 'm-1'), isNull);
      expect(await store.get('chat-1', 'm-2'), isNull);
      expect(await store.get('chat-1', 'm-3'), 'v3');
      expect(await store.get('chat-1', 'm-4'), 'v4');
    });

    test('prune is scoped to the chat', () async {
      final store = await openStore();
      await store.cache('chat-1', 'm-1', 'a');
      await store.cache('chat-2', 'm-1', 'b');

      await store.prune('chat-1', 0);

      expect(await store.get('chat-1', 'm-1'), isNull);
      expect(await store.get('chat-2', 'm-1'), 'b');
    });

    test('cached plaintext SURVIVES a HiveService restart (new instance, '
        'same keystore key) — the Signal "stored plaintext" guarantee', () async {
      final first = await openStore();
      await first.cache('chat-1', 'm-1', 'sobreviviente');
      await Hive.close();

      final second = await openStore();
      expect(await second.get('chat-1', 'm-1'), 'sobreviviente');
    });

    test('the on-disk box file contains no plaintext', () async {
      final store = await openStore();
      await store.cache('chat-1', 'm-1', 'SENTINEL_PLAINTEXT_987654');
      await Hive.close();

      final boxFile = File('${tempDir.path}/${HiveService.messageBoxName}.hive');
      expect(boxFile.existsSync(), isTrue);
      final bytes = boxFile.readAsBytesSync();
      expect(
        latin1.decode(bytes),
        isNot(contains('SENTINEL_PLAINTEXT_987654')),
      );
    });
  });
}

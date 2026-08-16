import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/storage_service.dart';

/// In-memory FlutterSecureStorage stand-in (mocktail) — no platform channels.
class _MockSecureStorage extends Mock implements FlutterSecureStorage {
  String? storedKey;
  int writeCount = 0;

  void setup() {
    when(() => read(key: any(named: 'key'))).thenAnswer((_) async => storedKey);
    when(
      () => write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((invocation) async {
      storedKey = invocation.namedArguments[#value] as String?;
      writeCount++;
    });
  }
}

void main() {
  late Directory tempDir;
  late _MockSecureStorage secureStorage;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('hive_test_');
    secureStorage = _MockSecureStorage()..setup();
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('HiveService encryption', () {
    test('init opens all four boxes with an encryption key', () async {
      final service = HiveService(secureStorage: secureStorage, hive: Hive);

      await service.init(initializeFlutter: false);

      expect(Hive.isBoxOpen(HiveService.configBoxName), isTrue);
      expect(Hive.isBoxOpen(HiveService.photoBoxName), isTrue);
      expect(Hive.isBoxOpen(HiveService.messageBoxName), isTrue);
      expect(Hive.isBoxOpen(HiveService.notificationBoxName), isTrue);
      final stored = secureStorage.storedKey;
      expect(stored, isNotNull);
      expect(base64Decode(stored!), hasLength(32));
      expect(secureStorage.writeCount, 1);
    });

    test('config cache putAll/get roundtrip', () async {
      final service = HiveService(secureStorage: secureStorage, hive: Hive);

      await service.init(initializeFlutter: false);
      await service.cacheConfig({'theme': 'dark', 'language': 'es'});

      expect(service.getCachedConfig(), {'theme': 'dark', 'language': 'es'});
    });

    test('empty config cache returns null', () async {
      final service = HiveService(secureStorage: secureStorage, hive: Hive);

      await service.init(initializeFlutter: false);

      expect(service.getCachedConfig(), isNull);
    });

    test('key is generated once and reused on the next init', () async {
      final service = HiveService(secureStorage: secureStorage, hive: Hive);

      await service.init(initializeFlutter: false);
      final firstKey = secureStorage.storedKey;

      await service.init(initializeFlutter: false);

      expect(secureStorage.storedKey, same(firstKey));
      expect(secureStorage.writeCount, 1);
    });

    test(
      'opening a box with a wrong key throws (encryption is active)',
      () async {
        final keyA = Hive.generateSecureKey();
        final keyB = Hive.generateSecureKey();
        final box = await Hive.openBox<String>(
          'config_cache',
          encryptionCipher: HiveAesCipher(keyA),
        );
        await box.put('secret', 'value');
        await Hive.close();

        // crashRecovery: false — a key mismatch must surface as an error, never
        // silently truncate (hive's default recovery would erase the box).
        // runZonedGuarded absorbs hive 2.2.3's duplicate-error leak on failed
        // opens (HiveImpl._openBox completes the opening completer with the
        // same error it rethrows) so it does not fail this test.
        Object? openError;
        await runZonedGuarded(() async {
          try {
            await Hive.openBox<String>(
              'config_cache',
              encryptionCipher: HiveAesCipher(keyB),
              crashRecovery: false,
            );
          } catch (error) {
            openError = error;
          }
        }, (_, _) {});
        await Future<void>.delayed(Duration.zero);

        expect(openError, isA<HiveError>());
      },
    );

    test('on-disk box file contains no plaintext', () async {
      final service = HiveService(secureStorage: secureStorage, hive: Hive);

      await service.init(initializeFlutter: false);
      await service.cacheConfig({'secret': 'SENTINEL_PLAINTEXT_987654'});
      await Hive.close();

      final boxFile = File('${tempDir.path}/config_cache.hive');
      expect(boxFile.existsSync(), isTrue);
      final bytes = boxFile.readAsBytesSync();
      expect(
        latin1.decode(bytes),
        isNot(contains('SENTINEL_PLAINTEXT_987654')),
      );
    });

    test(
      'lost key (fresh install after backup restore): boxes are recreated '
      'empty, cache data is treated as disposable',
      () async {
        final firstBoot = HiveService(secureStorage: secureStorage, hive: Hive);
        await firstBoot.init(initializeFlutter: false);
        await firstBoot.cacheConfig({'cached': 'value'});
        await Hive.close();

        secureStorage.storedKey = null;

        final secondBoot = HiveService(secureStorage: secureStorage, hive: Hive);
        // runZonedGuarded absorbs hive 2.2.3's duplicate-error leak on failed
        // opens (fires after the opening completes) so it never reaches the
        // global test error handler under full-suite load.
        await runZonedGuarded(() async {
          await secondBoot.init(initializeFlutter: false);
        }, (_, _) {});
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(Hive.isBoxOpen(HiveService.configBoxName), isTrue);
        expect(Hive.isBoxOpen(HiveService.photoBoxName), isTrue);
        expect(Hive.isBoxOpen(HiveService.messageBoxName), isTrue);
        expect(Hive.isBoxOpen(HiveService.notificationBoxName), isTrue);
        expect(secondBoot.getCachedConfig(), isNull);

        // The re-created boxes must be USABLE, not just open: the reset path
        // (EF-04) must never leave a box whose write path is wedged by a
        // leaked lock-file flock from the failed open.
        await secondBoot.cacheConfig({'fresh': '1'});
        expect(secondBoot.getCachedConfig(), {'fresh': '1'});
      },
      // Regression guard for the EF-04 flake: hive 2.2.3's failed-open close
      // chain is unawaited, so an immediate re-open could previously deadlock
      // on the leaked flock and hang past the 30 s default. The service must
      // complete the reset far faster than this.
      timeout: const Timeout(Duration(seconds: 20)),
    );
  });

  group('HiveService message cache (Signal plaintext-store backend)', () {
    test('cacheMessage/getCachedMessage roundtrip is scoped per (chat, message)',
        () async {
      final service = HiveService(secureStorage: secureStorage, hive: Hive);
      await service.init(initializeFlutter: false);

      await service.cacheMessage('chat-1', 'm-1', 'hola');
      await service.cacheMessage('chat-1', 'm-2', 'mundo');
      await service.cacheMessage('chat-2', 'm-1', 'otro chat');

      expect(service.getCachedMessage('chat-1', 'm-1'), 'hola');
      expect(service.getCachedMessage('chat-1', 'm-2'), 'mundo');
      expect(service.getCachedMessage('chat-2', 'm-1'), 'otro chat');
      expect(service.getCachedMessage('chat-1', 'm-9'), isNull);
      expect(service.getCachedMessage('chat-3', 'm-1'), isNull);
    });

    test('deleteCachedMessage removes only the addressed entry', () async {
      final service = HiveService(secureStorage: secureStorage, hive: Hive);
      await service.init(initializeFlutter: false);
      await service.cacheMessage('chat-1', 'm-1', 'a');
      await service.cacheMessage('chat-1', 'm-2', 'b');

      await service.deleteCachedMessage('chat-1', 'm-1');

      expect(service.getCachedMessage('chat-1', 'm-1'), isNull);
      expect(service.getCachedMessage('chat-1', 'm-2'), 'b');
    });

    test('pruneCachedMessages keeps the newest maxPerChat entries per chat',
        () async {
      final service = HiveService(secureStorage: secureStorage, hive: Hive);
      await service.init(initializeFlutter: false);
      for (var i = 0; i < 5; i++) {
        await service.cacheMessage('chat-1', 'm-$i', 'v$i');
      }
      await service.cacheMessage('chat-2', 'm-1', 'keep');

      await service.pruneCachedMessages('chat-1', 2);

      expect(service.getCachedMessage('chat-1', 'm-0'), isNull);
      expect(service.getCachedMessage('chat-1', 'm-1'), isNull);
      expect(service.getCachedMessage('chat-1', 'm-2'), isNull);
      expect(service.getCachedMessage('chat-1', 'm-3'), 'v3');
      expect(service.getCachedMessage('chat-1', 'm-4'), 'v4');
      expect(service.getCachedMessage('chat-2', 'm-1'), 'keep');
    });
  });
}

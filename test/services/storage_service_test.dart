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

    test('lost key (fresh install after backup restore): boxes are recreated '
        'empty, cache data is treated as disposable', () async {
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
    });
  });
}

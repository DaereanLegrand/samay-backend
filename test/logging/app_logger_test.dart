import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/logging/app_logger.dart';

void main() {
  late Directory tempDir;
  late AppLogger logger;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('samay_logger_test');
    logger = AppLogger(storageDir: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  String readLog() {
    final file = File('${tempDir.path}/${AppLogger.logFileName}');
    if (!file.existsSync()) return '';
    return file.readAsStringSync();
  }

  group('level methods', () {
    test('debug/info/warn/error/emergency write labeled entries', () {
      logger.debug('debug entry');
      logger.info('info entry');
      logger.warn('warn entry');
      logger.error('error entry');
      logger.emergency('emergency entry');

      final log = readLog();
      expect(log, contains('[Samay][DEBUG]'));
      expect(log, contains('debug entry'));
      expect(log, contains('[Samay][INFO]'));
      expect(log, contains('info entry'));
      expect(log, contains('[Samay][WARN]'));
      expect(log, contains('warn entry'));
      expect(log, contains('[Samay][ERROR]'));
      expect(log, contains('error entry'));
      expect(log, contains('[Samay][EMERGENCY]'));
      expect(log, contains('emergency entry'));
    });

    test('entries carry an ISO-8601 timestamp and message', () {
      logger.info('timed entry');
      final log = readLog();
      expect(
        log,
        matches(RegExp(
          r'\[Samay\]\[INFO\] \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z timed entry',
        )),
      );
    });

    test('error level preserves the stack trace', () {
      logger.error('failed', 'fake_stack_line');
      final log = readLog();
      expect(log, contains('[Samay][ERROR]'));
      expect(log, contains('failed'));
      expect(log, contains('fake_stack_line'));
    });
  });

  group('knownBenignError', () {
    test('cancelled operations downgrade to info', () {
      expect(
        logger.knownBenignError(StateError('Operation was Cancelled')),
        LogLevel.info,
      );
    });

    test('Future-already-completed downgrades to info', () {
      expect(
        logger.knownBenignError(StateError('Bad state: Future already completed')),
        LogLevel.info,
      );
    });

    test('MissingPluginException downgrades to warn', () {
      expect(
        logger.knownBenignError(MissingPluginException('No implementation found')),
        LogLevel.warn,
      );
    });

    test('unrelated errors are not classified', () {
      expect(logger.knownBenignError(Exception('boom')), isNull);
      expect(logger.knownBenignError(FormatException('bad')), isNull);
    });
  });

  group('crash marker', () {
    test('markCrash writes a readable marker', () async {
      await logger.markCrash('fatal blow', 'stack_one');

      final content = await logger.readCrashMarker();
      expect(content, isNotNull);
      expect(content, contains('[Samay][EMERGENCY]'));
      expect(content, contains('fatal blow'));
      expect(content, contains('stack_one'));
    });

    test('readCrashMarker returns null when no marker exists', () async {
      expect(await logger.readCrashMarker(), isNull);
    });

    test('clearCrashMarker removes the marker', () async {
      await logger.markCrash('fatal blow');
      expect(await logger.readCrashMarker(), isNotNull);

      await logger.clearCrashMarker();
      expect(await logger.readCrashMarker(), isNull);
    });

    test('recoverCrashMarker appends to samay_crash.log and clears', () async {
      await logger.markCrash('fatal blow', 'stack_two');

      final recovered = await logger.recoverCrashMarker();

      expect(recovered, contains('fatal blow'));
      expect(await logger.readCrashMarker(), isNull);

      final crashLog = File('${tempDir.path}/${AppLogger.crashLogFileName}');
      expect(crashLog.existsSync(), isTrue);
      expect(crashLog.readAsStringSync(), contains('fatal blow'));
      expect(crashLog.readAsStringSync(), contains('stack_two'));
    });

    test('recoverCrashMarker returns null with no pending crash', () async {
      expect(await logger.recoverCrashMarker(), isNull);
    });
  });

  test('AppLogger.instance is a singleton', () {
    expect(identical(AppLogger.instance, AppLogger.instance), isTrue);
  });
}

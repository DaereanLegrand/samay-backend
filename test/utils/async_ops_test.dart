import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/utils/async_ops.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('withRetry', () {
    test('succeeds after N transient failures (SocketException)', () async {
      var attempts = 0;
      final result = await withRetry<int>(
        () async {
          attempts++;
          if (attempts < 3) throw const SocketException('no route');
          return 42;
        },
        maxRetries: 3,
        initialDelay: const Duration(milliseconds: 1),
      );
      expect(result, 42);
      expect(attempts, 3);
    });

    test('succeeds after TimeoutException failures', () async {
      var attempts = 0;
      final result = await withRetry<String>(
        () async {
          attempts++;
          if (attempts == 1) throw TimeoutException('slow');
          return 'ok';
        },
        maxRetries: 2,
        initialDelay: const Duration(milliseconds: 1),
      );
      expect(result, 'ok');
      expect(attempts, 2);
    });

    test('stops immediately on non-retryable error (never re-invokes fn)', () async {
      var attempts = 0;
      await expectLater(
        withRetry<int>(
          () async {
            attempts++;
            throw ValidationError('email', 'Correo invalido');
          },
          maxRetries: 3,
          initialDelay: const Duration(milliseconds: 1),
        ),
        throwsA(isA<ValidationError>()),
      );
      expect(attempts, 1, reason: 'non-retryable error must not be retried');
    });

    test('never retries NotFoundError or PermissionError', () async {
      for (final error in [
        const NotFoundError('grupo'),
        PermissionError(),
      ]) {
        var attempts = 0;
        await expectLater(
          withRetry<int>(
            () async {
              attempts++;
              throw error;
            },
            maxRetries: 3,
            initialDelay: const Duration(milliseconds: 1),
          ),
          throwsA(isA<AppError>()),
        );
        expect(attempts, 1, reason: '$error must not be retried');
      }
    });

    test('retries AppError.NetworkError', () async {
      var attempts = 0;
      final result = await withRetry<int>(
        () async {
          attempts++;
          if (attempts == 1) throw NetworkError();
          return 7;
        },
        maxRetries: 2,
        initialDelay: const Duration(milliseconds: 1),
      );
      expect(result, 7);
      expect(attempts, 2);
    });

    test('retries PostgrestException with connection-class code (28*)', () async {
      var attempts = 0;
      final result = await withRetry<int>(
        () async {
          attempts++;
          if (attempts == 1) {
            throw const PostgrestException(message: 'connection failed', code: '28000');
          }
          return 1;
        },
        maxRetries: 2,
        initialDelay: const Duration(milliseconds: 1),
      );
      expect(result, 1);
      expect(attempts, 2);
    });

    test('does NOT retry PostgrestException with permanent codes', () async {
      var attempts = 0;
      await expectLater(
        withRetry<int>(
          () async {
            attempts++;
            throw const PostgrestException(message: 'already exists', code: '23505');
          },
          maxRetries: 3,
          initialDelay: const Duration(milliseconds: 1),
        ),
        throwsA(isA<PostgrestException>()),
      );
      expect(attempts, 1);
    });

    test('gives up after maxRetries and rethrows the last error', () async {
      var attempts = 0;
      await expectLater(
        withRetry<int>(
          () async {
            attempts++;
            throw const SocketException('always down');
          },
          maxRetries: 2,
          initialDelay: const Duration(milliseconds: 1),
        ),
        throwsA(isA<SocketException>()),
      );
      expect(attempts, 3, reason: 'initial attempt + 2 retries');
    });

    test('respects a custom shouldRetry predicate', () async {
      var attempts = 0;
      await expectLater(
        withRetry<int>(
          () async {
            attempts++;
            throw StateError('custom-transient');
          },
          maxRetries: 2,
          initialDelay: const Duration(milliseconds: 1),
          shouldRetry: (error) => error is StateError,
        ),
        throwsA(isA<StateError>()),
      );
      expect(attempts, 3, reason: 'custom predicate allowed retries');
    });

    test('backoffDelay follows capped exponential backoff with jitter', () {
      final rng = Random(42);
      final first = backoffDelay(1, const Duration(seconds: 1), 2, rng);
      final second = backoffDelay(2, const Duration(seconds: 1), 2, rng);
      expect(first.inMilliseconds, inInclusiveRange(0, 2000));
      expect(second.inMilliseconds, inInclusiveRange(0, 4000));
      expect(second.inMilliseconds, greaterThanOrEqualTo(first.inMilliseconds));
    });
  });

  group('withTimeout', () {
    test('throws TimeoutException with a clean message on a never-completing future',
        () async {
      final completer = Completer<String>();
      await expectLater(
        withTimeout(
          () => completer.future,
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
    });

    test('returns the value when the future completes in time', () async {
      final result = await withTimeout(
        () async => 'done',
        timeout: const Duration(milliseconds: 50),
      );
      expect(result, 'done');
    });

    test('propagates the original error (not wrapped)', () async {
      await expectLater(
        withTimeout(
          () async => throw ValidationError('data', 'bad'),
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<ValidationError>()),
      );
    });
  });

  group('resilient', () {
    test('timeout on first attempt then retry succeeds (timeout feeds retry)', () async {
      var attempts = 0;
      final result = await resilient<int>(
        () async {
          attempts++;
          if (attempts == 1) {
            await Completer<int>().future; // hangs -> per-attempt timeout
          }
          return 99;
        },
        timeout: const Duration(milliseconds: 10),
        maxRetries: 2,
        initialDelay: const Duration(milliseconds: 1),
      );
      expect(result, 99);
      expect(attempts, 2, reason: 'attempt 1 timed out, attempt 2 succeeded');
    });

    test('gives up when every attempt times out', () async {
      var attempts = 0;
      await expectLater(
        resilient<int>(
          () async {
            attempts++;
            return Completer<int>().future; // never completes -> timeout
          },
          timeout: const Duration(milliseconds: 10),
          maxRetries: 1,
          initialDelay: const Duration(milliseconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(attempts, 2);
    });

    test('non-retryable error surfaces immediately without retries', () async {
      var attempts = 0;
      await expectLater(
        resilient<int>(
          () async {
            attempts++;
            throw PermissionError();
          },
          timeout: const Duration(milliseconds: 50),
          maxRetries: 2,
          initialDelay: const Duration(milliseconds: 1),
        ),
        throwsA(isA<PermissionError>()),
      );
      expect(attempts, 1);
    });
  });
}

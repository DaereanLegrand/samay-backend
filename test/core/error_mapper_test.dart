import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/extensions/error_mapper.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _genericServerMessage = 'Error del servidor. Intenta de nuevo.';

void main() {
  group('AppError passthrough', () {
    test('returns the same instance for every AppError subtype', () {
      final errors = <AppError>[
        NetworkError(),
        const UnauthorizedError(),
        const ServerError(),
        const ServerError('detalle'),
        ValidationError('campo', 'problema'),
        PermissionError(),
        RateLimitError(),
        const NotFoundError(),
        const NotFoundError('grupo'),
      ];
      for (final error in errors) {
        expect(error.toAppError(), same(error), reason: '$error');
      }
    });
  });

  group('Stable error codes', () {
    test('every AppError subtype reports its exact stable code', () {
      final codes = <String, AppError>{
        'NETWORK_ERROR': NetworkError(),
        'AUTH_UNAUTHORIZED': const UnauthorizedError(),
        'SERVER_ERROR': const ServerError(),
        'VALIDATION_ERROR': ValidationError('campo', 'problema'),
        'PERMISSION_DENIED': PermissionError(),
        'RATE_LIMITED': RateLimitError(),
        'NOT_FOUND': const NotFoundError(),
        'NOT_CONFIGURED': NotConfiguredError(),
      };
      for (final entry in codes.entries) {
        expect(
          entry.value.code,
          entry.key,
          reason: '${entry.value.runtimeType} must report ${entry.key}',
        );
      }
    });
  });

  group('AuthException code mappings', () {
    for (final code in [
      'over_request_rate_limit',
      'over_email_send_rate_limit',
      'over_sms_send_rate_limit',
    ]) {
      test('$code → RateLimitError', () {
        expect(
          AuthException('rate limited', code: code).toAppError(),
          isA<RateLimitError>(),
        );
      });
    }

    test('invalid_credentials → ValidationError(credenciales)', () {
      final error = const AuthException(
        'Invalid login credentials',
        code: 'invalid_credentials',
      ).toAppError();
      expect(error, isA<ValidationError>());
      final validation = error as ValidationError;
      expect(validation.field, 'credenciales');
      expect(validation.issue, 'Correo o contraseña inválidos');
    });

    test('otp_expired → ValidationError(código)', () {
      final error = const AuthException(
        'OTP has expired',
        code: 'otp_expired',
      ).toAppError();
      expect(error, isA<ValidationError>());
      expect((error as ValidationError).field, 'código');
    });

    test('jwt/token/session in the message → UnauthorizedError', () {
      for (final msg in [
        'JWT expired',
        'Invalid token',
        'Session from this device has been terminated',
        'Your JWT token has expired and your refresh token could not be refreshed',
      ]) {
        expect(
          AuthException(msg).toAppError(),
          isA<UnauthorizedError>(),
          reason: msg,
        );
      }
    });

    test('known jwt code without keyword message → UnauthorizedError', () {
      // `bad_jwt` is the canonical server code (error-codes doc) — mapped
      // code-first, no message parsing needed.
      expect(
        const AuthException(
          'signature check failed',
          code: 'bad_jwt',
        ).toAppError(),
        isA<UnauthorizedError>(),
      );
    });

    test('session-lifecycle codes → UnauthorizedError', () {
      for (final code in [
        'session_expired',
        'session_not_found',
        'refresh_token_not_found',
        'refresh_token_already_used',
        'user_not_found',
        'no_authorization',
      ]) {
        expect(
          AuthException('some server message', code: code).toAppError(),
          isA<UnauthorizedError>(),
          reason: code,
        );
      }
    });

    test('unmapped code → faithful ServerError, not a fake category', () {
      expect(
        const AuthException(
          'something went wrong',
          code: 'some_unknown_code',
        ).toAppError(),
        isA<ServerError>(),
      );
    });

    test('null code + no keyword message → ServerError, no crash (null-safe)',
        () {
      expect(
        const AuthException('something happened').toAppError(),
        isA<ServerError>(),
      );
    });

    test('email_not_confirmed → ValidationError(correo)', () {
      final error = const AuthException(
        'Email not confirmed',
        code: 'email_not_confirmed',
      ).toAppError();
      expect(error, isA<ValidationError>());
      expect((error as ValidationError).field, 'correo');
    });

    test('weak_password → ValidationError(contraseña)', () {
      final error = const AuthException(
        'Password should be longer than 8 characters',
        code: 'weak_password',
      ).toAppError();
      expect(error, isA<ValidationError>());
      expect((error as ValidationError).field, 'contraseña');
    });

    test('user_banned → ValidationError(cuenta)', () {
      final error = const AuthException(
        'User is banned',
        code: 'user_banned',
      ).toAppError();
      expect(error, isA<ValidationError>());
      expect((error as ValidationError).field, 'cuenta');
    });

    test('request_timeout → NetworkError', () {
      expect(
        const AuthException('Request took too long', code: 'request_timeout')
            .toAppError(),
        isA<NetworkError>(),
      );
    });
  });

  group('PostgrestException code mappings', () {
    test('PGRST301 → UnauthorizedError', () {
      expect(
        const PostgrestException(
          message: 'JWT expired',
          code: 'PGRST301',
        ).toAppError(),
        isA<UnauthorizedError>(),
      );
    });

    test('23503 → ValidationError(data, Referencia inválida)', () {
      final error = const PostgrestException(
        message: 'insert or update on table violates foreign key constraint',
        code: '23503',
      ).toAppError();
      expect(error, isA<ValidationError>());
      final validation = error as ValidationError;
      expect(validation.field, 'data');
      expect(validation.issue, 'Referencia inválida');
    });

    test('23505 → ValidationError(data, Ya existe)', () {
      final error = const PostgrestException(
        message: 'duplicate key value violates unique constraint',
        code: '23505',
      ).toAppError();
      expect(error, isA<ValidationError>());
      final validation = error as ValidationError;
      expect(validation.field, 'data');
      expect(validation.issue, 'Ya existe');
    });

    test('42501 → PermissionError', () {
      expect(
        const PostgrestException(
          message: 'permission denied',
          code: '42501',
        ).toAppError(),
        isA<PermissionError>(),
      );
    });

    test('SR001 (search_users per-user limiter) → RateLimitError', () {
      final error = const PostgrestException(
        message: 'search rate limit exceeded',
        code: 'SR001',
      ).toAppError();
      expect(error, isA<RateLimitError>());
      expect(error.message, 'Demasiadas solicitudes. Espera un momento.');
    });

    test('HTTP 429 from the Kong route limiter (code falls back to the '
        'status string) → RateLimitError', () {
      final error = const PostgrestException(
        message: 'API rate limit exceeded',
        code: '429',
      ).toAppError();
      expect(error, isA<RateLimitError>());
      expect(error.message, 'Demasiadas solicitudes. Espera un momento.');
    });

    test('P0001 → ServerError carrying the server detail', () {
      final error = const PostgrestException(
        message: 'division by zero',
        code: 'P0001',
      ).toAppError();
      expect(error, isA<ServerError>());
      expect((error as ServerError).detail, 'division by zero');
    });

    for (final code in ['28000', '28502', '28P01']) {
      test('$code (28* connection class) → NetworkError', () {
        expect(
          PostgrestException(
            message: 'connection failed',
            code: code,
          ).toAppError(),
          isA<NetworkError>(),
        );
      });
    }

    for (final code in ['42601', '42P01', '42P17']) {
      test('$code (42* syntax/undefined class) → ServerError with detail', () {
        final error = PostgrestException(
          message: 'syntax error',
          code: code,
        ).toAppError();
        expect(error, isA<ServerError>());
        expect((error as ServerError).detail, 'syntax error');
      });
    }

    test('unmapped code → ServerError with server detail', () {
      final error = const PostgrestException(
        message: 'invalid input syntax for type integer',
        code: '22P02',
      ).toAppError();
      expect(error, isA<ServerError>());
      expect(
        (error as ServerError).detail,
        'invalid input syntax for type integer',
      );
    });

    test('null code → ServerError with server detail (null-safe)', () {
      final error = const PostgrestException(
        message: 'Unknown db error',
      ).toAppError();
      expect(error, isA<ServerError>());
      expect((error as ServerError).detail, 'Unknown db error');
    });
  });

  group('StorageException mappings', () {
    test('AccessDenied (upload RLS denial, 400) → PermissionError', () {
      final error = const StorageException(
        'new row violates row-level security policy',
        statusCode: '400',
        error: 'AccessDenied',
      ).toAppError();
      expect(error, isA<PermissionError>());
      expect(error.message, 'No tienes permiso para realizar esta acción.');
    });

    test('InvalidKey (403) → PermissionError', () {
      final error = const StorageException(
        'The request has invalid credentials',
        statusCode: '403',
        error: 'InvalidKey',
      ).toAppError();
      expect(error, isA<PermissionError>());
      expect(error.message, 'No tienes permiso para realizar esta acción.');
    });

    test('statusCode 42501 (Postgres RLS code surfaced by storage) → '
        'PermissionError', () {
      expect(
        const StorageException(
          'new row violates row-level security policy',
          statusCode: '42501',
        ).toAppError(),
        isA<PermissionError>(),
      );
    });

    test('JWT-expired (401) → UnauthorizedError', () {
      final error = const StorageException(
        'JWT token has expired',
        statusCode: '401',
        error: 'InvalidJWT',
      ).toAppError();
      expect(error, isA<UnauthorizedError>());
      expect(error.message, 'Sesión expirada. Inicia sesión de nuevo.');
    });

    test('ObjectNotFound (404) → NotFoundError', () {
      final error = const StorageException(
        'The resource was not found',
        statusCode: '404',
        error: 'ObjectNotFound',
      ).toAppError();
      expect(error, isA<NotFoundError>());
    });

    test('generic failure (500) → ServerError preserving the storage message',
        () {
      final error = const StorageException(
        'Internal server error while processing upload',
        statusCode: '500',
      ).toAppError();
      expect(error, isA<ServerError>());
      final server = error as ServerError;
      expect(server.detail, 'Internal server error while processing upload');
      expect(server.message, 'Internal server error while processing upload');
      expect(server.message, isNot(_genericServerMessage));
    });

    test('no statusCode/error → ServerError preserving the message', () {
      final error = const StorageException('Upload aborted by user').toAppError();
      expect(error, isA<ServerError>());
      expect((error as ServerError).detail, 'Upload aborted by user');
    });
  });

  group('FormatException', () {
    test('→ ValidationError(data, Formato inválido)', () {
      final error = const FormatException('bad format').toAppError();
      expect(error, isA<ValidationError>());
      expect((error as ValidationError).issue, 'Formato inválido');
    });
  });

  group('Network-class errors', () {
    test('SocketException → NetworkError carrying the original', () {
      const socket = SocketException('connection refused');
      final error = socket.toAppError();
      expect(error, isA<NetworkError>());
      final network = error as NetworkError;
      expect(network.original, isA<SocketException>());
      expect(identical(network.original, socket), isTrue);
    });

    test('HttpException → NetworkError carrying the original', () {
      const http = HttpException('404 not found');
      final error = http.toAppError();
      expect(error, isA<NetworkError>());
      final network = error as NetworkError;
      expect(network.original, isA<HttpException>());
      expect(identical(network.original, http), isTrue);
    });

    test('TimeoutException → NetworkError carrying the original (NEW)', () {
      final timeout = TimeoutException('Operation timed out after 10s');
      final error = timeout.toAppError();
      expect(error, isA<NetworkError>());
      final network = error as NetworkError;
      expect(network.original, isA<TimeoutException>());
      expect(identical(network.original, timeout), isTrue);
    });

    test('TimeoutException internals never leak into the message', () {
      final error = TimeoutException(
        'Operation timed out after 10s',
      ).toAppError();
      expect(error.message, 'Error de conexión. Verifica tu internet.');
      expect(error.message.contains('timed out'), isFalse);
      expect(error.message.contains('TimeoutException'), isFalse);
    });

    test('TimeoutException with a duration still maps to NetworkError', () {
      expect(
        TimeoutException(
          'Operation timed out after 10s',
          const Duration(seconds: 10),
        ).toAppError(),
        isA<NetworkError>(),
      );
    });
  });

  group('Unknown errors → user-safe fallback', () {
    test(
      'raw Exception → generic ServerError, raw internals NOT in message',
      () {
        final raw = Exception(
          'syntax error at lib/core/services/supabase_service.dart:88',
        );
        final error = raw.toAppError();
        expect(error, isA<ServerError>());
        expect(error.message, _genericServerMessage);
        expect(error.message.contains('syntax error'), isFalse);
        expect(error.message.contains('Exception'), isFalse);
        expect(error.message.contains('supabase_service'), isFalse);
        expect(error.message.contains('lib/core'), isFalse);
      },
    );

    test('StateError → generic ServerError with original preserved', () {
      final raw = StateError('Bad state: boom');
      final error = raw.toAppError();
      expect(error, isA<ServerError>());
      final server = error as ServerError;
      expect(server.detail, '');
      expect(error.message, _genericServerMessage);
      expect(identical(server.original, raw), isTrue);
      expect(
        server.original.toString(),
        contains('boom'),
        reason: 'original carries the raw error for logging',
      );
    });

    test('no type names or stack fragments leak for unknown errors', () {
      final error = Exception(
        'SecretStackLine@/private/var/folders/x',
      ).toAppError();
      expect(error.message, _genericServerMessage);
      expect(error.message.contains('SecretStackLine'), isFalse);
      expect(error.message.contains('Exception'), isFalse);
      expect(error.message.contains('/private/var'), isFalse);
    });

    test('non-empty String passes through verbatim (already user-safe)', () {
      final error = 'Correo o contraseña inválidos'.toAppError();
      expect(error, isA<ServerError>());
      expect(error.message, 'Correo o contraseña inválidos');
      expect((error as ServerError).detail, 'Correo o contraseña inválidos');
    });

    test('empty String → generic ServerError (nothing to show)', () {
      final error = ''.toAppError();
      expect(error, isA<ServerError>());
      expect(error.message, _genericServerMessage);
    });
  });

  group('original field (logging)', () {
    test('ServerError defaults to a null original', () {
      expect(const ServerError().original, isNull);
      expect(const ServerError('detail').original, isNull);
    });

    test('ServerError carries the original when provided', () {
      final raw = StateError('x');
      final error = ServerError('detail', raw);
      expect(error.detail, 'detail');
      expect(identical(error.original, raw), isTrue);
    });

    test('NetworkError defaults to a null original', () {
      expect(NetworkError().original, isNull);
    });
  });
}

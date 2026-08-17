import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/deep_links/deep_link_handler.dart';
import 'package:samay/core/router/route_paths.dart';

class _MockGoRouter extends Mock implements GoRouter {}

class _MockNavigatorKey extends Mock implements GlobalKey<NavigatorState> {}

void main() {
  late DeepLinkHandler handler;
  late _MockGoRouter router;

  setUpAll(() {
    registerFallbackValue(const RouteSettings(name: '/'));
  });

  setUp(() {
    handler = const DeepLinkHandler();
    router = _MockGoRouter();
  });

  group('parseDeepLink', () {
    test('returns Uri for samay:// event deep links', () {
      final uri = handler.parseDeepLink('samay://event/abc123');
      expect(uri, isNotNull);
      expect(uri!.scheme, 'samay');
      expect(uri.host, 'event');
      expect(uri.pathSegments, ['abc123']);
    });

    test('returns Uri for https event links', () {
      final uri = handler.parseDeepLink('https://vive.app/event/abc123');
      expect(uri, isNotNull);
      expect(uri!.scheme, 'https');
      expect(uri.pathSegments, ['event', 'abc123']);
    });

    test('returns Uri for http event links', () {
      final uri = handler.parseDeepLink('http://vive.app/event/abc123');
      expect(uri, isNotNull);
      expect(uri!.scheme, 'http');
    });

    test('returns null for unknown scheme', () {
      expect(handler.parseDeepLink('whatsapp://event/abc123'), isNull);
    });

    test('returns null for empty string', () {
      expect(handler.parseDeepLink(''), isNull);
    });

    test('returns null for string without scheme', () {
      expect(handler.parseDeepLink('just-some-text'), isNull);
    });

    test('returns null for https link without event path', () {
      expect(
        handler.parseDeepLink('https://vive.app/profile/abc123'),
        isNull,
      );
    });

    test('trims whitespace before parsing', () {
      final uri = handler.parseDeepLink('  samay://event/tok123  ');
      expect(uri, isNotNull);
      expect(uri!.pathSegments, ['tok123']);
    });

    test('returns null for malformed URI with no scheme separator', () {
      expect(handler.parseDeepLink(':///broken'), isNull);
    });

    test('returns null for non-event https path with only one segment', () {
      expect(
        handler.parseDeepLink('https://vive.app/event'),
        isNull,
      );
    });
  });

  group('extractEventToken', () {
    test('extracts token from samay://event/{token}', () {
      final uri = Uri.parse('samay://event/abc123');
      expect(handler.extractEventToken(uri), 'abc123');
    });

    test('extracts token from https://domain/event/{token}', () {
      final uri = Uri.parse('https://vive.app/event/abc123');
      expect(handler.extractEventToken(uri), 'abc123');
    });

    test('returns null when samay host is not event', () {
      final uri = Uri.parse('samay://profile/abc123');
      expect(handler.extractEventToken(uri), isNull);
    });

    test('returns null for samay with extra path segments', () {
      final uri = Uri.parse('samay://event/abc/extra');
      expect(handler.extractEventToken(uri), isNull);
    });

    test('returns null for https with wrong path shape', () {
      final uri = Uri.parse('https://vive.app/events/abc123');
      expect(handler.extractEventToken(uri), isNull);
    });

    test('returns null for samay with empty token', () {
      final uri = Uri.parse('samay://event/');
      expect(handler.extractEventToken(uri), isNull);
    });

    test('returns null for https with empty token', () {
      final uri = Uri.parse('https://vive.app/event/');
      expect(handler.extractEventToken(uri), isNull);
    });

    test('tolerates trailing slashes', () {
      final uri = Uri.parse('samay://event/abc123/');
      expect(handler.extractEventToken(uri), 'abc123');
    });

    test('tolerates multiple trailing slashes', () {
      final uri = Uri.parse('samay://event/abc123///');
      expect(handler.extractEventToken(uri), 'abc123');
    });

    test('handles token with special characters', () {
      final uri = Uri.parse('samay://event/tok%2B123');
      expect(handler.extractEventToken(uri), 'tok+123');
    });

    test('returns null for non-event http path', () {
      final uri = Uri.parse('http://vive.app/event');
      expect(handler.extractEventToken(uri), isNull);
    });

    test('samay://event with single empty segment returns null', () {
      final uri = Uri.parse('samay://event');
      expect(handler.extractEventToken(uri), isNull);
    });
  });

  group('handleDeepLink', () {
    test('returns false for non-Samay link', () async {
      final result = await handler.handleDeepLink(
        'https://google.com',
        router: router,
        resolveEventId: (_) async => 'id',
      );
      expect(result, false);
    });

    test('returns false for empty string', () async {
      final result = await handler.handleDeepLink(
        '',
        router: router,
        resolveEventId: (_) async => 'id',
      );
      expect(result, false);
    });

    test('returns false for random text', () async {
      final result = await handler.handleDeepLink(
        'not a link',
        router: router,
        resolveEventId: (_) async => 'id',
      );
      expect(result, false);
    });

    test('navigates to event detail on successful resolution', () async {
      when(
        () => router.go(RoutePaths.eventDetail('event-123')),
      ).thenReturn(null);

      final result = await handler.handleDeepLink(
        'samay://event/tok123',
        router: router,
        resolveEventId: (_) async => 'event-123',
      );

      expect(result, true);
      verify(() => router.go(RoutePaths.eventDetail('event-123'))).called(1);
    });

    test('returns false when resolveEventId returns null', () async {
      final result = await handler.handleDeepLink(
        'samay://event/tok123',
        router: router,
        resolveEventId: (_) async => null,
        failureMessage: 'Token inválido',
      );
      expect(result, false);
    });

    test('returns false when resolveEventId throws', () async {
      final result = await handler.handleDeepLink(
        'samay://event/tok123',
        router: router,
        resolveEventId: (_) async => throw Exception('network error'),
        failureMessage: 'Error de red',
      );
      expect(result, false);
    });

    test('navigates via https event link too', () async {
      when(
        () => router.go(RoutePaths.eventDetail('event-456')),
      ).thenReturn(null);

      final result = await handler.handleDeepLink(
        'https://vive.app/event/tok456',
        router: router,
        resolveEventId: (_) async => 'event-456',
      );

      expect(result, true);
      verify(() => router.go(RoutePaths.eventDetail('event-456'))).called(1);
    });

    test('returns false when token extraction fails even after parse', () async {
      final result = await handler.handleDeepLink(
        'samay://profile/someone',
        router: router,
        resolveEventId: (_) async => 'id',
      );
      expect(result, false);
    });
  });
}

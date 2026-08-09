import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/media_service.dart';
import 'package:samay/core/utils/image_processor.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MockSupabaseClient extends Mock implements SupabaseClient {
  _MockSupabaseClient(this.storage);

  /// `SupabaseClient.storage` is a `late final` field, which mocktail cannot
  /// stub — the mock exposes the same [storage] instance the test stubs
  /// (see the I-22 daily log MISTAKE block).
  @override
  final SupabaseStorageClient storage;
}

class _MockStorage extends Mock implements SupabaseStorageClient {}

class _MockFileApi extends Mock implements StorageFileApi {}

/// Per-pixel noise PNG — incompressible, so byte-size assertions are
/// meaningful (see test/utils/image_processor_test.dart for the rationale).
Future<Uint8List> _noisePng(int width, int height) async {
  final random = Random(42);
  final raw = Uint8List(width * height * 4);
  for (var i = 0; i < raw.length; i += 4) {
    raw[i] = random.nextInt(256);
    raw[i + 1] = random.nextInt(256);
    raw[i + 2] = random.nextInt(256);
    raw[i + 3] = 255;
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(raw);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  final bytes = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  descriptor.dispose();
  return bytes!.buffer.asUint8List();
}

/// Solid-color PNG via Canvas → `toByteData`.
Future<Uint8List> _solidPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF4B8BBE),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
  });

  group('MediaService.uploadGroupCover (PERF-03/M-36 wiring)', () {
    late _MockSupabaseClient client;
    late _MockStorage storage;
    late _MockFileApi fileApi;
    late MediaService service;

    setUp(() {
      storage = _MockStorage();
      client = _MockSupabaseClient(storage);
      fileApi = _MockFileApi();
      when(() => storage.from('groups')).thenReturn(fileApi);
      when(() => fileApi.uploadBinary(any(), any())).thenAnswer(
        (invocation) async => invocation.positionalArguments[0] as String,
      );
      when(() => fileApi.getPublicUrl(any())).thenAnswer(
        (invocation) =>
            'https://cdn.example/groups/${invocation.positionalArguments[0]}',
      );
      service = MediaService(client: client);
    });

    test('compresses a full-resolution payload before uploadBinary', () async {
      final input = await _noisePng(3000, 2000);
      expect(input.length, greaterThan(ImageProcessor.skipThresholdBytes));

      final url = await service.uploadGroupCover(input);

      expect(url, startsWith('https://cdn.example/groups/group_covers/'));
      final captured = verify(() => fileApi.uploadBinary(captureAny(), captureAny()))
          .captured;
      final path = captured[0] as String;
      final uploadedBytes = captured[1] as Uint8List;
      expect(path, startsWith('group_covers/'));
      expect(path, endsWith('.png'),
          reason: 'processed output is always PNG, whatever the source format');
      expect(uploadedBytes.length, lessThan(input.length),
          reason: 'downscaled payload must be smaller than the original');
    });

    test('passes small payloads through without processing', () async {
      final input = await _solidPng(800, 600);
      expect(input.length, lessThan(ImageProcessor.skipThresholdBytes));

      await service.uploadGroupCover(input);

      final captured = verify(() => fileApi.uploadBinary(captureAny(), captureAny()))
          .captured;
      expect(captured[1], equals(input),
          reason: 'cheap uploads must not pay the decode/encode cost');
    });

    test('returns the public URL of the uploaded object', () async {
      final input = await _solidPng(640, 480);
      final url = await service.uploadGroupCover(input);

      expect(url, startsWith('https://cdn.example/groups/group_covers/'));
      expect(url, endsWith('.png'));
    });
  });

  group('MediaService.uploadUserAvatar (PRFL gap — I-36)', () {
    late _MockSupabaseClient client;
    late _MockStorage storage;
    late _MockFileApi fileApi;
    late MediaService service;

    setUp(() {
      storage = _MockStorage();
      client = _MockSupabaseClient(storage);
      fileApi = _MockFileApi();
      when(() => storage.from('avatars')).thenReturn(fileApi);
      when(() => fileApi.uploadBinary(any(), any())).thenAnswer(
        (invocation) async => invocation.positionalArguments[0] as String,
      );
      when(() => fileApi.getPublicUrl(any())).thenAnswer(
        (invocation) =>
            'https://cdn.example/avatars/${invocation.positionalArguments[0]}',
      );
      service = MediaService(client: client);
    });

    test('compresses a full-resolution payload before uploadBinary', () async {
      final input = await _noisePng(3000, 2000);
      expect(input.length, greaterThan(ImageProcessor.skipThresholdBytes));

      final url = await service.uploadUserAvatar('user-1', input);

      expect(url, startsWith('https://cdn.example/avatars/avatars/user-1/'));
      final captured = verify(() => fileApi.uploadBinary(captureAny(), captureAny()))
          .captured;
      final path = captured[0] as String;
      final uploadedBytes = captured[1] as Uint8List;
      expect(path, startsWith('avatars/user-1/'));
      expect(path, endsWith('.png'),
          reason: 'processed output is always PNG, whatever the source format');
      expect(uploadedBytes.length, lessThan(input.length),
          reason: 'downscaled payload must be smaller than the original');
    });

    test('passes small payloads through without processing', () async {
      final input = await _solidPng(800, 600);
      expect(input.length, lessThan(ImageProcessor.skipThresholdBytes));

      await service.uploadUserAvatar('user-1', input);

      final captured = verify(() => fileApi.uploadBinary(captureAny(), captureAny()))
          .captured;
      expect(captured[1], equals(input),
          reason: 'cheap uploads must not pay the decode/encode cost');
    });

    test('returns the public URL of the uploaded object', () async {
      final input = await _solidPng(640, 480);
      final url = await service.uploadUserAvatar('user-1', input);

      expect(url, startsWith('https://cdn.example/avatars/avatars/user-1/'));
      expect(url, endsWith('.png'));
    });

    test('namespaces storage paths per user', () async {
      final input = await _solidPng(640, 480);

      await service.uploadUserAvatar('user-A', input);
      final capturedA = verify(() => fileApi.uploadBinary(captureAny(), captureAny()))
          .captured;
      expect(capturedA[0], startsWith('avatars/user-A/'));

      await service.uploadUserAvatar('user-B', input);
      final capturedB = verify(() => fileApi.uploadBinary(captureAny(), captureAny()))
          .captured;
      expect(capturedB[0], startsWith('avatars/user-B/'));
    });
  });
}

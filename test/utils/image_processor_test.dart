import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/utils/image_processor.dart';

/// Solid-color PNG via Canvas → `toByteData` (finding PERF-03 / M-36).
///
/// A solid fill compresses to a handful of bytes, so this helper is used
/// where the *pixel dimensions* (not the byte size) are the point — e.g. the
/// skip-path and threshold tests.
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

/// Per-pixel random-noise PNG built from raw RGBA via `ImageDescriptor.raw`.
///
/// Solid or gradient fills compress to near-nothing in PNG, which would make
/// "output smaller than input" vacuous. Real camera photos are dominated by
/// high-frequency detail, so the large-image test needs *incompressible*
/// pixels: noise guarantees the byte-size assertions are meaningful.
Future<Uint8List> _noisePng(int width, int height, {int seed = 42}) async {
  final random = Random(seed);
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

/// Decodes [bytes] back and returns `(width, height)` so tests can assert
/// the processed output really is a smaller image.
Future<(int, int)> _decodeDims(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final dims = (frame.image.width, frame.image.height);
  frame.image.dispose();
  codec.dispose();
  return dims;
}

Future<File> _writeTempPng(String name, Uint8List bytes) async {
  final dir = await Directory.systemTemp.createTemp('image_processor_test');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/$name.png');
  await file.writeAsBytes(bytes);
  return file;
}

void main() {
  group('ImageProcessor.shouldResize', () {
    test('returns false for a small file (below the threshold)', () async {
      final file = await _writeTempPng('small', await _solidPng(800, 600));
      expect(ImageProcessor.shouldResize(file), isFalse);
    });

    test('returns true for a large file (at or above the threshold)', () async {
      final file = await _writeTempPng('large', await _noisePng(1600, 900));
      expect(ImageProcessor.shouldResize(file), isTrue);
    });

    test('returns false when the file does not exist', () {
      final missing = File('/nonexistent/path/missing.png');
      expect(ImageProcessor.shouldResize(missing), isFalse);
    });
  });

  group('ImageProcessor.compress — large image path', () {
    test('downscales a 3000x2000 PNG so the long edge is at most maxLongEdge '
        'and the payload shrinks', () async {
      final input = await _noisePng(3000, 2000);
      final file = await _writeTempPng('big', input);

      final output = await ImageProcessor.compress(file);

      expect(output.length, greaterThan(0));
      expect(output.length, lessThan(input.length),
          reason: 'downscaled output must be a smaller payload');
      final (w, h) = await _decodeDims(output);
      expect(max(w, h), lessThanOrEqualTo(ImageProcessor.defaultMaxLongEdge));
      expect(max(w, h), greaterThan(0));
    });

    test('respects a custom maxLongEdge', () async {
      final input = await _noisePng(2000, 1000);
      final file = await _writeTempPng('custom', input);

      final output = await ImageProcessor.compress(file, maxLongEdge: 1000);

      final (w, h) = await _decodeDims(output);
      expect(max(w, h), lessThanOrEqualTo(1000));
    });
  });

  group('ImageProcessor.compress — skip paths', () {
    test('a large-dimension image within the limit is returned untouched '
        '(dimension skip)', () async {
      final input = await _noisePng(1600, 900);
      expect(input.length, greaterThan(ImageProcessor.skipThresholdBytes),
          reason: 'fixture must be over the byte threshold for this test');
      final file = await _writeTempPng('within-limit', input);

      final output = await ImageProcessor.compress(file);

      expect(output, equals(input),
          reason: 'no resize needed — original bytes must pass through');
    });

    test('a small file below the byte threshold is returned untouched '
        '(size skip)', () async {
      final input = await _solidPng(800, 600);
      expect(input.length, lessThan(ImageProcessor.skipThresholdBytes));
      final file = await _writeTempPng('tiny', input);

      final output = await ImageProcessor.compress(file);

      expect(output, equals(input),
          reason: 'cheap uploads must not pay the decode/encode cost');
    });
  });

  group('ImageProcessor.compress — invalid input', () {
    test('throws a ValidationError-shaped error for non-image data',
        () async {
      final file = await _writeTempPng(
        'junk',
        Uint8List.fromList(List<int>.generate(64, (i) => i)),
      );

      expect(
        () => ImageProcessor.compress(file),
        throwsA(isA<ValidationError>()),
      );
    });
  });
}

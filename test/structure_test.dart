import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.path;

  group('lib directory structure', () {
    for (final path in [
      'lib/main.dart',
      'lib/app.dart',
      'lib/core/theme',
      'lib/core/config',
      'lib/core/router',
      'lib/core/services',
      'lib/core/providers',
      'lib/features/auth',
      'lib/features/profile',
      'lib/features/friends',
      'lib/features/groups',
      'lib/features/events',
      'lib/features/qr',
      'lib/features/chat',
      'lib/features/feed',
      'lib/features/photos',
      'lib/features/notifications',
      'lib/features/shards',
      'lib/features/cosmetics',
      'lib/features/minigames',
      'lib/features/party_finder',
      'lib/features/subscriptions',
      'lib/features/video_souvenir',
      'lib/shared/widgets',
      'lib/shared/models',
      'lib/shared/providers',
    ]) {
      test('$path exists', () {
        final entity = Directory('$root/$path');
        final file = File('$root/$path');
        expect(entity.existsSync() || file.existsSync(), isTrue,
            reason: '$path should exist');
      });
    }
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.path;

  final libRoot = Directory('$root/lib');
  final integrationRoot = Directory('$root/integration_test');

  Iterable<File> dartFiles(Directory dir) => dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'));

  String relative(String path) => path.substring(root.length + 1);

  group('entrypoints', () {
    test('lib/main.dart exists', () {
      expect(File('$root/lib/main.dart').existsSync(), isTrue,
          reason: 'lib/main.dart should exist');
    });

    test('lib/app.dart exists', () {
      expect(File('$root/lib/app.dart').existsSync(), isTrue,
          reason: 'lib/app.dart should exist');
    });
  });

  group('core layers', () {
    for (final name in [
      'theme',
      'config',
      'router',
      'services',
      'providers',
      'models',
      'design_tokens',
      'logging',
      'utils',
    ]) {
      test('lib/core/$name exists', () {
        expect(Directory('$root/lib/core/$name').existsSync(), isTrue,
            reason: 'lib/core/$name should exist');
      });
    }
  });

  group('feature modules', () {
    for (final name in ['auth', 'profile', 'friends', 'groups', 'feed']) {
      test('lib/features/$name exists', () {
        expect(Directory('$root/lib/features/$name').existsSync(), isTrue,
            reason: 'lib/features/$name should exist');
      });
    }
  });

  group('feature sublayers (ARC-01, M-23)', () {
    test('every lib/features/<feature>/ has a screens/ subdir with a Dart '
        'file', () {
      final broken = <String>[];
      final features = Directory('$root/lib/features').listSync()
          .whereType<Directory>();
      expect(features.length, greaterThan(0),
          reason: 'lib/features/ should contain at least one feature dir');
      for (final dir in features) {
        final name = dir.path.split(Platform.pathSeparator).last;
        final screens = Directory('${dir.path}/screens');
        if (!screens.existsSync()) {
          broken.add('$name (no screens/ subdir)');
          continue;
        }
        final hasDart = screens.listSync().whereType<File>().any(
            (f) => f.path.endsWith('.dart'));
        if (!hasDart) broken.add('$name (screens/ has no .dart file)');
      }
      expect(broken, isEmpty,
          reason: 'feature dirs missing a screens/ sublayer (ARC-01/M-23): '
              '$broken');
    });
  });

  group('shared and crypto', () {
    test('lib/shared/widgets exists', () {
      expect(Directory('$root/lib/shared/widgets').existsSync(), isTrue,
          reason: 'lib/shared/widgets should exist');
    });

    test('lib/crypto exists', () {
      expect(Directory('$root/lib/crypto').existsSync(), isTrue,
          reason: 'lib/crypto should exist');
    });
  });

  group('integration suite', () {
    test('has at least one flow test file', () {
      expect(integrationRoot.existsSync(), isTrue,
          reason: 'integration_test/ should exist');
      expect(
        dartFiles(integrationRoot)
            .where((file) => file.path.endsWith('_test.dart'))
            .length,
        greaterThan(0),
        reason: 'integration_test/ should contain at least one *_test.dart',
      );
    });

    test('support harness files exist', () {
      for (final name in ['fake_supabase.dart', 'test_app.dart', 'test_users.dart']) {
        expect(File('$root/integration_test/support/$name').existsSync(), isTrue,
            reason: 'integration_test/support/$name should exist');
      }
    });

    test('README.md exists', () {
      expect(File('$root/integration_test/README.md').existsSync(), isTrue,
          reason: 'integration_test/README.md should exist');
    });
  });

  group('dynamic invariants', () {
    test('every lib/ subdirectory contains at least one Dart file', () {
      final empty = <String>[];
      for (final area in libRoot.listSync().whereType<Directory>()) {
        for (final dir in area.listSync().whereType<Directory>()) {
          if (dartFiles(dir).isEmpty) {
            empty.add(relative(dir.path));
          }
        }
      }
      expect(empty, isEmpty,
          reason: 'empty placeholder directories (TST-10/L-13): $empty');
    });
  });
}

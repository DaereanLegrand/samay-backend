import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late YamlMap pubspec;

  setUp(() {
    final file = File('pubspec.yaml');
    final content = file.readAsStringSync();
    pubspec = loadYaml(content) as YamlMap;
  });

  test('has expected name', () {
    expect(pubspec['name'], 'samay');
  });

  group('dependencies', () {
    late YamlMap deps;

    setUp(() {
      deps = pubspec['dependencies'] as YamlMap;
    });

    for (final pkg in [
      'flutter_riverpod',
      'riverpod',
      'go_router',
      'flutter_secure_storage',
      'hive',
      'hive_flutter',
      'supabase_flutter',
      'image_picker',
      'intl',
      'flutter_localizations',
      'cached_network_image',
      'freezed_annotation',
      'json_annotation',
      'path_provider',
      'uuid',
    ]) {
      test('includes $pkg', () {
        expect(deps.containsKey(pkg), isTrue, reason: '$pkg not found in dependencies');
      });
    }

    for (final pkg in [
      'qr_flutter',
      'mobile_scanner',
      'purchases_flutter',
      'share_plus',
      'flutter_dotenv',
    ]) {
      test('does not include dead dependency $pkg', () {
        expect(deps.containsKey(pkg), isFalse,
            reason: '$pkg is a dead dependency (DEP-01..DEP-04, SEC-09) and must be removed');
      });
    }
  });

  group('dev_dependencies', () {
    late YamlMap devDeps;

    setUp(() {
      devDeps = pubspec['dev_dependencies'] as YamlMap;
    });

    for (final pkg in [
      'yaml',
      'flutter_test',
      'mocktail',
    ]) {
      test('includes $pkg', () {
        expect(devDeps.containsKey(pkg), isTrue, reason: '$pkg not found in dev_dependencies');
      });
    }
  });

  group('declared assets', () {
    test('every asset declared under flutter: exists on disk', () {
      final flutterSection = pubspec['flutter'] as YamlMap;
      final missing = <String>[];

      final assets = flutterSection['assets'];
      if (assets is YamlList) {
        for (final asset in assets.whereType<String>()) {
          if (!File(asset).existsSync()) {
            missing.add(asset);
          }
        }
      }

      final fonts = flutterSection['fonts'];
      if (fonts is YamlList) {
        for (final entry in fonts.whereType<YamlMap>()) {
          final files = entry['fonts'];
          if (files is YamlList) {
            for (final file in files.whereType<String>()) {
              if (!File(file).existsSync()) {
                missing.add(file);
              }
            }
          }
        }
      }

      expect(missing, isEmpty,
          reason: 'declared assets missing on disk: $missing');
    });
  });
}

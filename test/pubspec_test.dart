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
}

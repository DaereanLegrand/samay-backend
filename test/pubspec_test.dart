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
      'qr_flutter',
      'mobile_scanner',
      'purchases_flutter',
      'image_picker',
      'share_plus',
      'intl',
      'flutter_dotenv',
    ]) {
      test('includes $pkg', () {
        expect(deps.containsKey(pkg), isTrue, reason: '$pkg not found in dependencies');
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

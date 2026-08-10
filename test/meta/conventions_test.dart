import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.path;

  Iterable<File> filesUnder(String dir) => Directory('$root/$dir')
      .listSync(recursive: true)
      .whereType<File>();

  String relative(String path) => path.substring(root.length + 1);

  List<String> offendersIn(List<String> paths, RegExp pattern) {
    final offenders = <String>[];
    for (final path in paths) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (pattern.hasMatch(lines[i])) {
          offenders.add('${relative(path)}:${i + 1}');
        }
      }
    }
    return offenders;
  }

  List<String> libDartFilesOutsideLogger() => filesUnder('lib')
      .where((f) =>
          f.path.endsWith('.dart') &&
          f.path != '$root/lib/core/logging/app_logger.dart')
      .map((f) => f.path)
      .toList();

  List<String> scriptPaths() {
    final scripts = <String>['$root/Makefile', '$root/test_runner.sh'];
    for (final dir in const ['tools', 'test', 'supabase', 'supabase-testing']) {
      scripts.addAll(filesUnder(dir)
          .where((f) => f.path.endsWith('.sh'))
          .map((f) => f.path));
    }
    return scripts;
  }

  group('logging conventions', () {
    test('no print() calls in lib/ outside the logger', () {
      final offenders =
          offendersIn(libDartFilesOutsideLogger(), RegExp(r'\bprint\s*\('));
      expect(offenders, isEmpty,
          reason: 'print() in lib/ — use AppLogger '
              '(lib/core/logging/app_logger.dart): $offenders');
    });

    test('debugPrint() only inside the logger', () {
      final offenders = offendersIn(
          libDartFilesOutsideLogger(), RegExp(r'debugPrint\s*\('));
      expect(offenders, isEmpty,
          reason: 'debugPrint() outside app_logger.dart — use AppLogger: '
              '$offenders');
    });
  });

  group('feature structure', () {
    test('every lib/features/<feature>/ has a screen or provider file', () {
      final broken = <String>[];
      final screenOrProvider =
          RegExp(r'(_screen|_provider|_providers)\.dart$');
      for (final dir
          in Directory('$root/lib/features').listSync().whereType<Directory>()) {
        final name = dir.path.split(Platform.pathSeparator).last;
        final dartFiles = filesUnder('lib/features/$name')
            .where((f) => f.path.endsWith('.dart'))
            .toList();
        if (dartFiles.isEmpty) {
          broken.add('${relative(dir.path)} (no dart files — empty dir)');
        } else if (!dartFiles.any((f) => screenOrProvider.hasMatch(f.path))) {
          broken.add(
              '${relative(dir.path)} (no *_screen.dart / *_provider.dart file)');
        }
      }
      expect(broken, isEmpty,
          reason: 'feature dirs without a screens/providers file: $broken');
    });
  });

  group('approved port map', () {
    test('no hardcoded Juega-owned host ports in lib/, integration_test/, or '
        'scripts', () {
      final banned = RegExp(
        r'localhost:54321|localhost:5432(?!\d)|'
        r'127\.0\.0\.1:54321|127\.0\.0\.1:5432(?!\d)',
      );
      final scanPaths = <String>[
        ...filesUnder('lib').map((f) => f.path),
        ...filesUnder('integration_test').map((f) => f.path),
        ...scriptPaths(),
      ];
      final offenders = offendersIn(scanPaths, banned);
      expect(offenders, isEmpty,
          reason: 'hardcoded localhost Juega ports (5432/54321) — Samay must '
              'use the approved map (54382/54386/...): $offenders');
    });
  });

  group('pubspec dead dependencies', () {
    test('DEP-02..04 + SEC-09 packages absent from the dependencies section', () {
      final content = File('$root/pubspec.yaml').readAsStringSync();
      final lines = content.split('\n');
      final depsStart = lines.indexWhere((l) => l.trimLeft() == 'dependencies:');
      final depsEnd =
          lines.indexWhere((l) => l.trimLeft() == 'dev_dependencies:');
      expect(depsStart, isNot(-1),
          reason: 'pubspec.yaml is missing the dependencies: section');
      expect(depsEnd, isNot(-1),
          reason: 'pubspec.yaml is missing the dev_dependencies: section');
      final section = lines.sublist(depsStart + 1, depsEnd).join('\n');
      final dead = <String>[];
      for (final pkg in const [
        'share_plus',
        'flutter_dotenv',
      ]) {
        if (RegExp('^\\s*$pkg\\s*:', multiLine: true).hasMatch(section)) {
          dead.add(pkg);
        }
      }
      expect(dead, isEmpty,
          reason: 'dead dependencies (DEP-04, SEC-09 flutter_dotenv) must '
              'not be re-added to pubspec.yaml: $dead');
    });
  });
}

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

    test('ARC-01: no .dart files directly in a feature dir root (M-23 '
        'restructure)', () {
      final flat = <String>[];
      for (final dir
          in Directory('$root/lib/features').listSync().whereType<Directory>()) {
        final name = dir.path.split(Platform.pathSeparator).last;
        final rootFiles = dir.listSync().whereType<File>().where(
            (f) => f.path.endsWith('.dart')).toList();
        if (rootFiles.isNotEmpty) {
          flat.add('$name: '
              '${rootFiles.map((f) => f.path.split(Platform.pathSeparator).last).join(', ')}');
        }
      }
      expect(flat, isEmpty,
          reason: 'feature files must live in screens/providers/widgets/'
              'logic/ subdirs, not the feature root (ARC-01/M-23): $flat');
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

  group('feature-flag route gating (I-69)', () {
    // LIVE routes: no FlagGate required. Any GoRoute NOT in this allowlist
    // must be wrapped in FlagGate carrying the flag mapped in [gatedRoutes] —
    // the release knob for its feature (I-49 system, I-69 audit 2026-08-09).
    const liveRoutes = <String>{
      // auth flow
      'RoutePaths.welcome',
      'RoutePaths.banned',
      'RoutePaths.login',
      'RoutePaths.signup',
      'RoutePaths.verify',
      'RoutePaths.ageGate',
      'RoutePaths.privacyTerms',
      'RoutePaths.profileSetup',
      // shell tabs without a kill-switch knob
      'RoutePaths.mainGroups',
      'RoutePaths.mainProfile',
      // events: detail/edit are live; the hub/create/invite stay gated
      "RoutePaths.eventDetail(':eventId')",
      "RoutePaths.eventEdit(':eventId')",
      // groups: live feature
      'RoutePaths.groupCreate',
      "RoutePaths.groupDetail(':groupId')",
      "RoutePaths.groupMembers(':groupId')",
      "RoutePaths.donateToGroup(':groupId')",
      "RoutePaths.inviteToGroup(':groupId')",
      'RoutePaths.groupsLeaderboard',
      // friends + public profiles: live features
      'RoutePaths.userSearch',
      "RoutePaths.userProfile(':userId')",
      'RoutePaths.friendsRequests',
      'RoutePaths.friendsList',
      'RoutePaths.blockedUsers',
      // shards economy (I-64: live, reads-only) + settings
      'RoutePaths.shardsLedger',
      'RoutePaths.settings',
      'RoutePaths.deleteAccount',
      'RoutePaths.profileEdit',
    };

    // Non-live routes (or live routes whose flag is the kill-switch knob) and
    // the flag their builder MUST gate on. Kept in lockstep with
    // lib/core/feature_flags.dart.
    const gatedRoutes = <String, String>{
      'RoutePaths.mainFeed': 'AppFeatureFlag.feed',
      'RoutePaths.mainEvents': 'AppFeatureFlag.events',
      'RoutePaths.mainNotifications': 'AppFeatureFlag.notifications',
      "RoutePaths.eventInvite(':eventId')": 'AppFeatureFlag.events',
      "RoutePaths.eventPhotos(':eventId')": 'AppFeatureFlag.photoUpload',
      "RoutePaths.eventCollage(':eventId')": 'AppFeatureFlag.photoUpload',
      "RoutePaths.createGroupEvent(':groupId')": 'AppFeatureFlag.events',
      "RoutePaths.minigames(':groupId')": 'AppFeatureFlag.minigames',
      "RoutePaths.chat(':chatId')": 'AppFeatureFlag.chat',
      "RoutePaths.qr(':eventId')": 'AppFeatureFlag.qr',
      "RoutePaths.scanner(':eventId')": 'AppFeatureFlag.qr',
      'RoutePaths.subscriptions': 'AppFeatureFlag.subscriptions',
      'RoutePaths.partyFinder': 'AppFeatureFlag.partyFinder',
      'RoutePaths.cosmetics': 'AppFeatureFlag.cosmeticsSection',
    };

    // Every GoRoute(path: ...) in app_router.dart, paired with its full route
    // block (balanced-paren scan — robust to any formatting). The path value
    // is matched as its RoutePaths expression, never a resolved string.
    List<(String, String)> goRoutesWithPaths(String source) {
      final pathPattern =
          RegExp(r"""path:\s*([A-Za-z0-9_.:'"/()]+)""");
      final routes = <(String, String)>[];
      var cursor = 0;
      while (true) {
        final open = source.indexOf('GoRoute(', cursor);
        if (open == -1) break;
        var depth = 0;
        var close = open;
        for (; close < source.length; close++) {
          if (source[close] == '(') depth++;
          if (source[close] == ')') {
            depth--;
            if (depth == 0) break;
          }
        }
        final block = source.substring(open, close + 1);
        final path = pathPattern.firstMatch(block)?.group(1);
        if (path != null) routes.add((path, block));
        cursor = close + 1;
      }
      return routes;
    }

    test('every non-live route is wrapped in FlagGate with its flag', () {
      final source =
          File('$root/lib/core/router/app_router.dart').readAsStringSync();
      final routes = goRoutesWithPaths(source);
      final seenPaths = routes.map((r) => r.$1).toSet();
      final problems = <String>[];
      for (final (path, block) in routes) {
        if (liveRoutes.contains(path)) continue;
        final flag = gatedRoutes[path];
        if (flag == null) {
          problems.add('$path: no gate decision — add it to liveRoutes or '
              'gatedRoutes (I-69 audit)');
        } else if (!block.contains('FlagGate') || !block.contains(flag)) {
          problems.add('$path: expected FlagGate($flag) in its builder');
        }
      }
      for (final path in gatedRoutes.keys) {
        if (!seenPaths.contains(path)) {
          problems.add('$path: gatedRoutes entry not found in app_router.dart');
        }
      }
      expect(problems, isEmpty,
          reason: 'feature-flag route gating violations: $problems');
    });
  });
}

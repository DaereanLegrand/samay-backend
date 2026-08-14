import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.path;

  Iterable<File> filesUnder(String dir) =>
      Directory('$root/$dir').listSync(recursive: true).whereType<File>();

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
      .where(
        (f) =>
            f.path.endsWith('.dart') &&
            f.path != '$root/lib/core/logging/app_logger.dart',
      )
      .map((f) => f.path)
      .toList();

  List<String> scriptPaths() {
    final scripts = <String>['$root/Makefile', '$root/test_runner.sh'];
    for (final dir in const ['tools', 'test', 'supabase', 'supabase-testing']) {
      scripts.addAll(
        filesUnder(dir).where((f) => f.path.endsWith('.sh')).map((f) => f.path),
      );
    }
    return scripts;
  }

  group('logging conventions', () {
    test('no print() calls in lib/ outside the logger', () {
      final offenders = offendersIn(
        libDartFilesOutsideLogger(),
        RegExp(r'\bprint\s*\('),
      );
      expect(
        offenders,
        isEmpty,
        reason:
            'print() in lib/ — use AppLogger '
            '(lib/core/logging/app_logger.dart): $offenders',
      );
    });

    test('debugPrint() only inside the logger', () {
      final offenders = offendersIn(
        libDartFilesOutsideLogger(),
        RegExp(r'debugPrint\s*\('),
      );
      expect(
        offenders,
        isEmpty,
        reason:
            'debugPrint() outside app_logger.dart — use AppLogger: '
            '$offenders',
      );
    });
  });

  group('feature structure', () {
    test('every lib/features/<feature>/ has a screen or provider file', () {
      final broken = <String>[];
      final screenOrProvider = RegExp(r'(_screen|_provider|_providers)\.dart$');
      for (final dir in Directory(
        '$root/lib/features',
      ).listSync().whereType<Directory>()) {
        final name = dir.path.split(Platform.pathSeparator).last;
        final dartFiles = filesUnder(
          'lib/features/$name',
        ).where((f) => f.path.endsWith('.dart')).toList();
        if (dartFiles.isEmpty) {
          broken.add('${relative(dir.path)} (no dart files — empty dir)');
        } else if (!dartFiles.any((f) => screenOrProvider.hasMatch(f.path))) {
          broken.add(
            '${relative(dir.path)} (no *_screen.dart / *_provider.dart file)',
          );
        }
      }
      expect(
        broken,
        isEmpty,
        reason: 'feature dirs without a screens/providers file: $broken',
      );
    });

    test('ARC-01: no .dart files directly in a feature dir root (M-23 '
        'restructure)', () {
      final flat = <String>[];
      for (final dir in Directory(
        '$root/lib/features',
      ).listSync().whereType<Directory>()) {
        final name = dir.path.split(Platform.pathSeparator).last;
        final rootFiles = dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList();
        if (rootFiles.isNotEmpty) {
          flat.add(
            '$name: '
            '${rootFiles.map((f) => f.path.split(Platform.pathSeparator).last).join(', ')}',
          );
        }
      }
      expect(
        flat,
        isEmpty,
        reason:
            'feature files must live in screens/providers/widgets/'
            'logic/ subdirs, not the feature root (ARC-01/M-23): $flat',
      );
    });

    test('ARC-03: no .dart files directly in the lib/core root (M-24 '
        'restructure)', () {
      final flat = Directory('$root/lib/core')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(
        flat,
        isEmpty,
        reason:
            'lib/core/ must contain only subdirectories (config, '
            'design_tokens, errors, extensions, ...) — no stray files at '
            'the core root (ARC-03/M-24): '
            '${flat.map((f) => f.path.split(Platform.pathSeparator).last).join(', ')}',
      );
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
      expect(
        offenders,
        isEmpty,
        reason:
            'hardcoded localhost Juega ports (5432/54321) — Samay must '
            'use the approved map (54382/54386/...): $offenders',
      );
    });
  });

  group('pubspec dead dependencies', () {
    test(
      'DEP-02..04 + SEC-09 packages absent from the dependencies section',
      () {
        final content = File('$root/pubspec.yaml').readAsStringSync();
        final lines = content.split('\n');
        final depsStart = lines.indexWhere(
          (l) => l.trimLeft() == 'dependencies:',
        );
        final depsEnd = lines.indexWhere(
          (l) => l.trimLeft() == 'dev_dependencies:',
        );
        expect(
          depsStart,
          isNot(-1),
          reason: 'pubspec.yaml is missing the dependencies: section',
        );
        expect(
          depsEnd,
          isNot(-1),
          reason: 'pubspec.yaml is missing the dev_dependencies: section',
        );
        final section = lines.sublist(depsStart + 1, depsEnd).join('\n');
        final dead = <String>[];
        for (final pkg in const ['share_plus', 'flutter_dotenv']) {
          if (RegExp('^\\s*$pkg\\s*:', multiLine: true).hasMatch(section)) {
            dead.add(pkg);
          }
        }
        expect(
          dead,
          isEmpty,
          reason:
              'dead dependencies (DEP-04, SEC-09 flutter_dotenv) must '
              'not be re-added to pubspec.yaml: $dead',
        );
      },
    );
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
      // U-14 R3: password recovery is part of the live auth flow (no flag).
      'RoutePaths.forgotPassword',
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
    // lib/core/config/feature_flags.dart (M-24: moved from the core root).
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
      final pathPattern = RegExp(r"""path:\s*([A-Za-z0-9_.:'"/()]+)""");
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
      final source = File(
        '$root/lib/core/router/app_router.dart',
      ).readAsStringSync();
      final routes = goRoutesWithPaths(source);
      final seenPaths = routes.map((r) => r.$1).toSet();
      final problems = <String>[];
      for (final (path, block) in routes) {
        if (liveRoutes.contains(path)) continue;
        final flag = gatedRoutes[path];
        if (flag == null) {
          problems.add(
            '$path: no gate decision — add it to liveRoutes or '
            'gatedRoutes (I-69 audit)',
          );
        } else if (!block.contains('FlagGate') || !block.contains(flag)) {
          problems.add('$path: expected FlagGate($flag) in its builder');
        }
      }
      for (final path in gatedRoutes.keys) {
        if (!seenPaths.contains(path)) {
          problems.add('$path: gatedRoutes entry not found in app_router.dart');
        }
      }
      expect(
        problems,
        isEmpty,
        reason: 'feature-flag route gating violations: $problems',
      );
    });
  });

  group('opencode project config (M-25, ARC-08/TOOL-05/L-02)', () {
    Map<String, dynamic> opencodeConfig() =>
        jsonDecode(File('$root/.opencode/opencode.json').readAsStringSync())
            as Map<String, dynamic>;

    test('.opencode/ exists with a README and the agents dir', () {
      expect(
        Directory('$root/.opencode').existsSync(),
        isTrue,
        reason: 'ARC-08/TOOL-05/L-02: .opencode/ must exist (M-25)',
      );
      expect(
        File('$root/.opencode/README.md').existsSync(),
        isTrue,
        reason: 'the .opencode README documents agents + lock protocol',
      );
      expect(
        Directory('$root/.opencode/agents').existsSync(),
        isTrue,
        reason: 'project agents live in .opencode/agents/',
      );
    });

    test('config JSON parses and carries the opencode schema header', () {
      final cfg = opencodeConfig();
      expect(
        cfg['\$schema'],
        'https://opencode.ai/config.json',
        reason: 'the config must validate against the opencode schema',
      );
    });

    test('instructions reference AGENT-RULES.md + FILE-OWNERSHIP.md', () {
      final instructions = (opencodeConfig()['instructions'] as List)
          .cast<String>()
          .join('\n');
      expect(
        instructions,
        contains('AGENTS.md'),
        reason: 'project context must inject AGENTS.md',
      );
      expect(
        instructions,
        contains('AGENT-RULES.md'),
        reason: 'the file-semaphore protocol must be injected (M-25)',
      );
      expect(
        instructions,
        contains('FILE-OWNERSHIP.md'),
        reason: 'the ownership map must be injected (M-25)',
      );
    });

    test('permission block allows commit/push, denies destructive git ops', () {
      final bash = (opencodeConfig()['permission'] as Map)['bash'] as Map;
      expect(
        bash['*'],
        'allow',
        reason:
            'permissions stay on opencode defaults — only git '
            'mutations are denied',
      );
      expect(
        bash['git commit*'],
        'allow',
        reason:
            'commit allowed since 2026-08-14 (product decision — the '
            'campaign is over; the human authorizes commits in-session). '
            'Destructive git operations below stay denied.',
      );
      expect(
        bash['git push*'],
        'allow',
        reason:
            'push allowed since 2026-08-14 (product decision — same '
            'authorization as commit; the remote branch is pushed at '
            'explicit human request)',
      );
      for (final op in const [
        'git pull*',
        'git am*',
        'git cherry-pick*',
        'git rebase*',
        'git merge*',
        'git reset*',
        'git checkout*',
        'git switch*',
        'git clean*',
        'git stash*',
      ]) {
        expect(
          bash[op],
          'deny',
          reason:
              '$op can destroy another agent\'s uncommitted work '
              '(AGENT-RULES §0.5) — must stay denied',
        );
      }
    });

    test('the three campaign subagents ship as .opencode/agents/*.md', () {
      for (final name in const [
        'reviewer',
        'security-check',
        'docs-verifier',
      ]) {
        expect(
          File('$root/.opencode/agents/$name.md').existsSync(),
          isTrue,
          reason: 'the $name subagent must exist (M-25)',
        );
      }
    });
  });

  group('design-token spacing literals (U-03)', () {
    final sharedWidgets = filesUnder(
      'lib/shared/widgets',
    ).where((f) => f.path.endsWith('.dart')).map((f) => f.path).toList();

    // Kept raw values (documented in the U-03 audit table): no design token
    // equals them, so replacing would change visuals. 14 = v_button vertical
    // padding (doc §5.1 pins 14px — the LUXE sweep hoisted it into the
    // `VButton._padding` const, line 34); 10 = compact one-off banner
    // paddings.
    // NOTE: the guard regex is line-based, so multi-line EdgeInsets (the
    // formatted form) are invisible to it — these entries document the
    // keepers for the single-line form.
    const edgeInsetsAllowlist = <String>{
      'lib/shared/widgets/v_button.dart:34',
      'lib/shared/widgets/error_banner.dart:35',
      'lib/shared/widgets/error_banner.dart:62',
    };

    test('EdgeInsets values 10–19 must come from AppSpacing tokens or the '
        'allowlist', () {
      // Pragmatic guard: any EdgeInsets (all/symmetric/fromLTRB/only) whose
      // arguments contain a raw 10-19 literal has a token counterpart
      // (md 12 / lg 16) or is a documented keeper (14/10 — see allowlist).
      final rawEdgeInsets = RegExp(
        r'EdgeInsets\.(?:all|symmetric|fromLTRB|only)\([^)]*\b1[0-9]\b[^)]*\)',
      );
      final offenders = offendersIn(
        sharedWidgets,
        rawEdgeInsets,
      ).where((site) => !edgeInsetsAllowlist.contains(site)).toList();
      expect(
        offenders,
        isEmpty,
        reason:
            'raw EdgeInsets 10-19 in shared widgets — use AppSpacing '
            '(md 12 / lg 16) or document a keeper in the U-03 allowlist: '
            '$offenders',
      );
    });

    // 56px icons were the U-12 restyle targets; U-05 restyled both sites to
    // `AppIconSizes.xxl` (48) per §5.7/§5.9, so the allowlist is empty.
    const iconSizeAllowlist = <String>{};

    test('Icon sizes 50–59 in shared widgets must be allowlisted', () {
      final rawIconSize = RegExp(r'\bsize:\s*5[0-9]\b');
      final offenders = offendersIn(
        sharedWidgets,
        rawIconSize,
      ).where((site) => !iconSizeAllowlist.contains(site)).toList();
      expect(
        offenders,
        isEmpty,
        reason:
            'raw 50-59px icon sizes in shared widgets — no token '
            'matches; must be a documented keeper: $offenders',
      );
    });
  });

  group('state-widget sweep guard (U-21)', () {
    // M-28/UI-04 (U-21, 2026-08-11): every full-area loading/empty/error
    // state in feature screens must go through the shared state widgets
    // (VLoadingView/VEmptyView/ErrorView — lib/shared/widgets/state_views.dart
    // + error_view.dart, DISCO-DESIGN-SYSTEM §5.8/§5.9). Raw spinners are
    // allowed ONLY for inline/button contexts that are NOT screen-level
    // states: busy buttons, per-row actions, upload progress, pagination
    // loaders, scan-processing chips. Shared widgets (v_button.dart,
    // state_views.dart) live outside lib/features and are exempt.
    //
    // Path:line entries below pin the justified inline-spinner sites so a
    // future screen-state regression fails this guard. The regex matches the
    // constructor form only (a bare word in a doc comment doesn't trip it).
    const rawSpinnerAllowlist = <String>{
      // photo gallery: 18px upload-button spinner in the AppBar action
      // photo gallery: 18px upload-button spinner in the AppBar action
      // (line 148 since the XL-13 mint restyle).
      'lib/features/photos/screens/photo_gallery_screen.dart:148',
      // requests: R11 per-row busy spinner (16px, in a row action; line
      // 374 since the XL-09 mint restyle).
      'lib/features/friends/screens/requests_screen.dart:374',
      // edit profile: 16px avatar-upload spinner inside the avatar circle
      // (line 218 since the XL-08 gold restyle).
      'lib/features/profile/screens/edit_profile_screen.dart:218',
      // qr scanner: 16px scan-processing chip (inline in the scan overlay;
      // line 384 since the XL-13 LUXE restyle (scan line + overlay edits).
      'lib/features/qr/screens/qr_scanner_screen.dart:384',
      // chat: 20px pagination loader row (list stays visible; line 186
      // since the XL-18 chat polish (bubble cap + token spacing)).
      'lib/features/chat/screens/chat_screen.dart:186',
      // invite: 20px AppBar-action spinner while sending (line 113 since
      // the XL-10 LUXE restyle of the invite search ring).
      'lib/features/groups/screens/invite_screen.dart:113',
      // photo gallery: 20px upload-overlay spinner (line 155 since the
      // XL-13 mint restyle).
      'lib/features/photos/screens/photo_gallery_screen.dart:155',
    };

    test('no raw CircularProgressIndicator in lib/features — state widgets '
        'only (M-28/UI-04/U-21)', () {
      final featureFiles = filesUnder(
        'lib/features',
      ).where((f) => f.path.endsWith('.dart')).map((f) => f.path).toList();
      final raw = RegExp(r'CircularProgressIndicator\s*\(');
      final offenders = offendersIn(
        featureFiles,
        raw,
      ).where((site) => !rawSpinnerAllowlist.contains(site)).toList();
      expect(
        offenders,
        isEmpty,
        reason:
            'raw CircularProgressIndicator in a feature screen — use '
            'VLoadingView/VEmptyView/ErrorView from '
            'lib/shared/widgets/state_views.dart (DISCO §5.8/§5.9); only '
            'inline busy contexts may keep a spinner (document them in the '
            'U-21 allowlist): $offenders',
      );
    });
  });

  group('shared-widget palette guard (U-05)', () {
    final sharedWidgets = filesUnder(
      'lib/shared/widgets',
    ).where((f) => f.path.endsWith('.dart')).map((f) => f.path).toList();

    // DISCO-DESIGN-SYSTEM.md §2: colors must come from AppColors/semantic
    // aliases. White/black/transparent are the doc's own P2 primitives
    // ("keep it white" / black backgrounds) — allowed directly. Everything
    // else (red/green/grey/blue/amber/...) is banned, including the
    // alpha-variant Material constants (white24 etc.).
    final bannedColor = RegExp(
      r'Colors\.(red|green|grey|gray|blue|amber|orange|purple|pink|teal|'
      r'cyan|indigo|brown|lime|yellow|deepOrange|deepPurple|lightBlue|'
      r'lightGreen|blueGrey|white10|white12|white24|white30|white38|'
      r'white54|white60|white70|black12|black26|black38|black45|black54|'
      r'black87)',
    );

    test('no raw hue Colors.* in lib/shared/widgets — tokens only (§2/§5)', () {
      final offenders = offendersIn(sharedWidgets, bannedColor);
      expect(
        offenders,
        isEmpty,
        reason:
            'raw Material hue colors in shared widgets — use '
            'AppColors / semantic aliases (AppColors.error, '
            'AppColors.statusOnline, ...): $offenders',
      );
    });

    test('no ad-hoc Color(0x…) hex literals in lib/shared/widgets (§8.1)', () {
      final hex = RegExp(r'Color\(0x[0-9A-Fa-f]+\)');
      final offenders = offendersIn(sharedWidgets, hex);
      expect(
        offenders,
        isEmpty,
        reason:
            'ad-hoc hex colors in shared widgets — every color must '
            'come from a design token (design doc §8 "Extending the '
            'system"): $offenders',
      );
    });
  });

  group('lint rules + pre-commit hooks (M-26, CQ-08/TOOL-04)', () {
    test('analysis_options.yaml enables the three custom lints', () {
      final content = File('$root/analysis_options.yaml').readAsStringSync();
      for (final rule in const [
        'prefer_single_quotes',
        'prefer_const_constructors',
        'unnecessary_late',
      ]) {
        expect(
          content,
          contains('$rule: true'),
          reason:
              'CQ-08 (M-26): $rule must stay enabled in '
              'analysis_options.yaml — see the M-26 daily log',
        );
      }
    });

    test('tool/pre-commit.sh exists and is executable', () {
      final script = File('$root/tool/pre-commit.sh');
      expect(
        script.existsSync(),
        isTrue,
        reason: 'TOOL-04 (M-26): tool/pre-commit.sh is the pre-commit gate',
      );
      expect(
        script.statSync().mode & 0x111,
        isNot(0),
        reason: 'tool/pre-commit.sh must be executable (chmod +x)',
      );
    });

    test('tool/hooks/pre-commit exists, is executable, and delegates', () {
      final hook = File('$root/tool/hooks/pre-commit');
      expect(
        hook.existsSync(),
        isTrue,
        reason:
            'TOOL-04 (M-26): tool/hooks/pre-commit is the git wrapper '
            '(core.hooksPath target)',
      );
      expect(
        hook.statSync().mode & 0x111,
        isNot(0),
        reason: 'tool/hooks/pre-commit must be executable (chmod +x)',
      );
      expect(
        hook.readAsStringSync(),
        contains('tool/pre-commit.sh'),
        reason:
            'the git hook must delegate to tool/pre-commit.sh so the '
            'gate logic lives in ONE place',
      );
    });

    test('Makefile exposes make install-hooks', () {
      final content = File('$root/Makefile').readAsStringSync();
      expect(
        content,
        contains('install-hooks'),
        reason:
            'TOOL-04 (M-26): make install-hooks wires '
            'core.hooksPath=tool/hooks — document it in DEVELOPMENT-WORKFLOW',
      );
    });
  });

  group('launcher icons (TOOL-06, U-20)', () {
    final pubspec = File('$root/pubspec.yaml').readAsStringSync();

    test('pubspec declares flutter_launcher_icons with the TOOL-06 config '
        'section', () {
      expect(
        pubspec,
        contains('flutter_launcher_icons: ^0.14.4'),
        reason:
            'TOOL-06: flutter_launcher_icons must be a dev dependency '
            '(0.14.x line — Juega parity, verified publisher)',
      );
      final lines = pubspec.split('\n');
      // The config section is the top-level `flutter_launcher_icons:` line
      // (the dev dependency is the indented `  flutter_launcher_icons:`
      // line — exact equality picks the section). Its body runs until the
      // next column-0 key or EOF.
      final sectionStart = lines.indexWhere(
        (l) => l == 'flutter_launcher_icons:',
      );
      final sectionEnd = lines.indexWhere(
        (l) => sectionStart >= 0 && l.isNotEmpty && !l.startsWith(' '),
        sectionStart + 1,
      );
      final section = sectionStart == -1
          ? null
          : lines
                .sublist(
                  sectionStart,
                  sectionEnd == -1 ? lines.length : sectionEnd,
                )
                .join('\n');
      expect(
        section,
        isNotNull,
        reason: 'TOOL-06: a flutter_launcher_icons: config section is missing',
      );
      for (final expected in const [
        'image_path:',
        'assets/icons/app_icon.png',
        'android: true',
        'ios: true',
        'remove_alpha_ios: true',
      ]) {
        expect(
          section,
          contains(expected),
          reason: 'TOOL-06: config must carry "$expected"',
        );
      }
    });

    test('launcher source icon exists as a >=1MB 1024x1024 PNG', () {
      final file = File('$root/assets/icons/app_icon.png');
      expect(
        file.existsSync(),
        isTrue,
        reason:
            'TOOL-06: assets/icons/app_icon.png (the regenerable source) '
            'is missing — run `dart run tool/icon_gen.dart`',
      );
      final bytes = file.readAsBytesSync();
      expect(
        bytes.length,
        greaterThanOrEqualTo(1024 * 1024),
        reason: 'the source icon must be >=1MB (1024x1024 RGB art)',
      );
      expect(
        bytes.sublist(0, 8),
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
        reason: 'the source icon must be a PNG (magic signature)',
      );
      int be32(int at) =>
          (bytes[at] << 24) |
          (bytes[at + 1] << 16) |
          (bytes[at + 2] << 8) |
          bytes[at + 3];
      // IHDR: length(4) 'IHDR'(4) width(4) height(4) — width at offset 16.
      expect(be32(16), 1024, reason: 'IHDR width must be 1024');
      expect(be32(20), 1024, reason: 'IHDR height must be 1024');
    });

    test('android launcher icon sets are generated (legacy mipmaps + '
        'adaptive anydpi)', () {
      for (final dpi in const ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
        expect(
          File(
            '$root/android/app/src/main/res/mipmap-$dpi/ic_launcher.png',
          ).existsSync(),
          isTrue,
          reason:
              'TOOL-06: legacy launcher icon missing for mipmap-$dpi — '
              're-run `dart run flutter_launcher_icons`',
        );
      }
      final anydpi = '$root/android/app/src/main/res/mipmap-anydpi-v26';
      expect(
        File('$anydpi/ic_launcher.xml').existsSync(),
        isTrue,
        reason:
            'TOOL-06: the adaptive icon XML is missing — '
            'adaptive_icon_background/foreground must be configured',
      );
      // flutter_launcher_icons 0.14.4 renders the adaptive foreground into
      // density-scaled drawable-*dpi/ dirs (referenced by the XML above),
      // with the black background declared as a color resource.
      expect(
        File(
          '$root/android/app/src/main/res/drawable-mdpi/'
          'ic_launcher_foreground.png',
        ).existsSync(),
        isTrue,
        reason: 'TOOL-06: the adaptive foreground drawable is missing',
      );
      final colors = File('$root/android/app/src/main/res/values/colors.xml');
      expect(
        colors.existsSync(),
        isTrue,
        reason: 'TOOL-06: colors.xml (adaptive background color) is missing',
      );
      expect(
        colors.readAsStringSync(),
        contains('ic_launcher_background'),
        reason: 'TOOL-06: the adaptive background color must be declared',
      );
    });

    test('iOS AppIcon set is generated (16+ PNGs + Contents.json)', () {
      final appiconset = Directory(
        '$root/ios/Runner/Assets.xcassets/AppIcon.appiconset',
      );
      expect(
        appiconset.existsSync(),
        isTrue,
        reason: 'TOOL-06: the iOS AppIcon set directory is missing',
      );
      final pngs = appiconset
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'))
          .toList();
      expect(
        pngs.length,
        greaterThanOrEqualTo(16),
        reason:
            'TOOL-06: the iOS AppIcon set must carry the full size matrix '
            '(16 pngs + the marketing 1024) — found ${pngs.length}',
      );
      expect(
        File('${appiconset.path}/Contents.json').existsSync(),
        isTrue,
        reason: 'TOOL-06: AppIcon Contents.json is missing',
      );
    });

    test(
      'android:label is the user-facing brand name Samay (M-29 drift #2)',
      () {
        final manifest = File(
          '$root/android/app/src/main/AndroidManifest.xml',
        ).readAsStringSync();
        final label = RegExp(
          r'android:label="([^"]+)"',
        ).firstMatch(manifest)?.group(1);
        expect(
          label,
          'Samay',
          reason:
              'M-29 issue #2: android:label must match iOS/web ("Samay") — '
              'the internal pubspec name "samay" is not the home-screen label',
        );
      },
    );
  });
}

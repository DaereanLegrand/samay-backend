import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_icon_sizes.dart';
import 'package:samay/core/design_tokens/app_typography.dart';
import 'package:samay/core/models/user_profile.dart';
import 'package:samay/core/repositories/friends_repository.dart';
import 'package:samay/core/repositories/repository_providers.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/features/profile/providers/profile_providers.dart';
import 'package:samay/features/profile/screens/delete_account_screen.dart';
import 'package:samay/features/profile/screens/edit_profile_screen.dart';
import 'package:samay/features/profile/screens/profile_screen.dart';
import 'package:samay/features/profile/screens/public_profile_screen.dart';
import 'package:samay/features/profile/screens/settings_screen.dart';
import 'package:samay/features/profile/widgets/profile_avatar.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/state_views.dart';
import 'package:samay/shared/widgets/v_button.dart';
import 'package:samay/shared/widgets/v_card.dart';
import 'package:samay/shared/widgets/v_shard_icon.dart';
import '../../support/fake_supabase_http.dart' as support;

/// Profile-screens disco restyle ledger tests (U-09, Phase 4.4).
///
/// Pins the visual changes from DISCO-DESIGN-SYSTEM §5 applied screen-by-
/// screen (the ledger in `docs/development/phase-04-ui/2026-08-11_U09-
/// profile-restyle.md`): avatar surfaceAlt + border ring, Playfair username,
/// VCard balance card with the gold shard icon, mutedStrong bio, hairline
/// group separators, glowPink danger rows, token-clean theme SegmentedButton,
/// glowAccent public-profile primary action, glowPink-outlined delete CTA.
/// Flow/text is byte-identical — the existing profile_screens_test /
/// avatar_flow_test / delete_account_flow_test assertions stay untouched.

const _userId = '11111111-1111-1111-1111-111111111111';

class _StubProfileFetcher {
  _StubProfileFetcher(this._onFetch);

  final Future<Map<String, dynamic>?> Function() _onFetch;

  Future<Map<String, dynamic>?> call() => _onFetch();
}

class _StubProfileNotifier extends MyProfileNotifier {
  _StubProfileNotifier(this.fetcher);

  final _StubProfileFetcher fetcher;

  @override
  Future<Map<String, dynamic>?> build() => fetcher.call();
}

class _StubGroupsFetcher {
  _StubGroupsFetcher(this._onFetch);

  final Future<List<Map<String, dynamic>>> Function() _onFetch;

  Future<List<Map<String, dynamic>>> call() => _onFetch();
}

class _StubGroupsNotifier extends ProfileGroupsNotifier {
  _StubGroupsNotifier(this.fetcher);

  final _StubGroupsFetcher fetcher;

  @override
  Future<List<Map<String, dynamic>>> build() => fetcher.call();
}

/// Profile row mirroring the real `users` table shape.
Map<String, dynamic> _profile({String? bio = 'hola mundo'}) => {
      'username': 'dana',
      if (bio != null) 'bio': bio, // ignore: use_null_aware_elements

      'personal_shards': 120,
      'preshards': 3,
    };

Widget _wrap(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: SamayTheme.dark,
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

List<Override> _profileOverrides({
  List<Map<String, dynamic>>? groups,
}) {
  final profileFetcher = _StubProfileFetcher(() async => _profile());
  final groupsFetcher =
      _StubGroupsFetcher(() async => groups ?? const []);
  return [
    myProfileProvider.overrideWith(() => _StubProfileNotifier(profileFetcher)),
    myGroupsProvider.overrideWith(() => _StubGroupsNotifier(groupsFetcher)),
  ];
}

/// The avatar's outer ring container: the [Container] that carries the
/// circle decoration inside [ProfileAvatar].
Container _avatarRing(WidgetTester tester) {
  final avatar = find.byType(ProfileAvatar);
  expect(avatar, findsOneWidget);
  return tester.widget<Container>(
    find.descendant(of: avatar, matching: find.byType(Container)).first,
  );
}

/// The glow-soft stack the theme bakes into `headlineLarge` (U-02).
List<Shadow> get _playfairGlow => AppTypography.fancyTitle(
      AppTypography.headlineLarge,
      soft: true,
    ).shadows!;

void main() {
  setUpAll(() => support.initSupabaseHarness(sessionEmail: 'user@samay.test'));

  group('ProfileScreen header (§3.2/§5.3/§5.6 — U-09 ledger)', () {
    testWidgets('avatar renders surfaceAlt fill + border ring + white '
        'initials', (tester) async {
      await tester.pumpWidget(_wrap(
        const ProfileScreen(),
        overrides: _profileOverrides(),
      ));
      await tester.pumpAndSettle();

      final ring = _avatarRing(tester);
      final decoration = ring.decoration as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      expect(decoration.color, AppColors.surfaceAlt,
          reason: 'initials sit on surfaceAlt (§5 avatar treatment)');
      expect(
        decoration.border,
        Border.all(color: AppColors.border, width: 1),
        reason: 'avatar ring = the §2.1 avatar-ring token border #333333',
      );

      final initials = tester.widget<Text>(
        find.descendant(
          of: find.byType(ProfileAvatar),
          matching: find.text('DA'),
        ),
      );
      expect(initials.style?.color, AppColors.white);
      expect(initials.style?.fontSize, 24);
    });

    testWidgets('username renders in Playfair headlineLarge with the glow',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const ProfileScreen(),
        overrides: _profileOverrides(),
      ));
      await tester.pumpAndSettle();

      final username = tester.widget<Text>(find.text('dana'));
      expect(username.style?.fontFamily, AppTypography.playfair);
      expect(username.style?.fontStyle, FontStyle.italic);
      expect(username.style?.fontSize, 28);
      expect(username.style?.shadows, _playfairGlow);
    });

    testWidgets('balance card is a VCard with the gold lg shard icon and '
        'token text', (tester) async {
      await tester.pumpWidget(_wrap(
        const ProfileScreen(),
        overrides: _profileOverrides(),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(VCard), findsOneWidget);
      final shard = tester.widget<VShardIcon>(find.byType(VShardIcon));
      expect(shard.color, AppColors.currencyShards,
          reason: '§5.6 — the diamond is gold (13.71:1)');
      expect(shard.size, AppIconSizes.lg,
          reason: '§5.6 — balance cards use the lg 24 size');
      expect(find.text('120 shards'), findsOneWidget);
      expect(find.text('3 preshards'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(VCard), matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget,
        reason: 'the ledger link affordance survives the card swap',
      );
    });

    testWidgets('bio renders mutedStrong (§2.4 AA)', (tester) async {
      await tester.pumpWidget(_wrap(
        const ProfileScreen(),
        overrides: _profileOverrides(),
      ));
      await tester.pumpAndSettle();

      final bio = tester.widget<Text>(find.text('hola mundo'));
      expect(bio.style?.color, AppColors.mutedStrong);
    });

    testWidgets('group tiles are separated by hairline dividers',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const ProfileScreen(),
        overrides: _profileOverrides(groups: const [
          {'id': 'g1', 'name': 'Fiesta Club', 'group_shards': 42},
          {'id': 'g2', 'name': 'Casa Bar', 'group_shards': 7},
        ]),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(Divider), findsOneWidget,
          reason: '2 group tiles → 1 hairline separator between them');
      final firstDivider = find.byType(Divider).first;
      // The Divider carries no explicit color — the U-04 dividerTheme paints
      // it; resolve the theme the widget consumes at its position.
      // The M3 Divider resolves widget.color ?? dividerTheme.color — the
      // U-04 dividerTheme is the hairline source (ThemeData.dividerColor is
      // the M2 fallback and reads white; asserting the real source instead).
      expect(
        Theme.of(tester.element(firstDivider)).dividerTheme.color,
        AppColors.hairline,
        reason: 'dividers resolve the U-04 dividerTheme (hairline)',
      );
    });
  });

  group('EditProfileScreen (§5.2/§5.8 — U-09 ledger)', () {
    testWidgets('avatar placeholder uses the shared token avatar',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const EditProfileScreen(),
        overrides: _profileOverrides(),
      ));
      await tester.pumpAndSettle();

      final ring = _avatarRing(tester);
      final decoration = ring.decoration as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      expect(decoration.color, AppColors.surfaceAlt);
      expect(
        decoration.border,
        Border.all(color: AppColors.border, width: 1),
      );
      // The camera-change affordance survives (white circle + black icon).
      expect(find.byIcon(Icons.camera_alt), findsOneWidget);
    });

    testWidgets('bio field keeps the token VInput (mutedStrong label)',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const EditProfileScreen(),
        overrides: _profileOverrides(),
      ));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration?.labelStyle?.color, AppColors.mutedStrong);
    });
  });

  group('SettingsScreen (§2.4/§5.4/danger — U-09 ledger)', () {
    testWidgets('destructive delete row renders glowPink icon + label',
        (tester) async {
      await tester.pumpWidget(_wrap(const SettingsScreen()));
      await tester.pumpAndSettle();
      // The settings list is taller than the 600px test viewport and builds
      // lazily — scroll the destructive row into view first.
      await tester.scrollUntilVisible(find.text('Eliminar mi cuenta'), 100);

      final label = tester.widget<Text>(find.text('Eliminar mi cuenta'));
      expect(label.style?.color, AppColors.error,
          reason: 'danger *text* = the error semantic (glowPink 6.00:1 AA; '
              'glowPinkDeep is AA-large-only and banned for normal-size '
              'text by §2.5 rule 6)');
      final icon = tester.widget<Icon>(find.byIcon(Icons.delete_forever));
      expect(icon.color, AppColors.error);
    });

    testWidgets('theme SegmentedButton is token-clean (white selected/black '
        'text, white side)', (tester) async {
      await tester.pumpWidget(_wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      final segmented = tester.widget<SegmentedButton<ThemeMode>>(
        find.byType(SegmentedButton<ThemeMode>),
      );
      final style = segmented.style!;
      // styleFrom folds selected/unselected colors into the segment
      // backgroundColor/foregroundColor properties, resolved per state.
      expect(
        style.backgroundColor!.resolve({WidgetState.selected}),
        AppColors.white,
      );
      expect(
        style.backgroundColor!.resolve(const {}),
        Colors.transparent,
      );
      expect(
        style.foregroundColor!.resolve({WidgetState.selected}),
        AppColors.discoBlack,
      );
      expect(
        style.foregroundColor!.resolve(const {}),
        AppColors.white,
      );
      expect(
        style.side!.resolve(const {}),
        const BorderSide(color: AppColors.white),
      );
      expect(
        style.shape!.resolve(const {}),
        const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      );
    });

    testWidgets('version footer renders mutedStrong (§2.4)', (tester) async {
      await tester.pumpWidget(_wrap(const SettingsScreen()));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Samay v1.0.0'), 100);

      final version = tester.widget<Text>(find.text('Samay v1.0.0'));
      expect(version.style?.color, AppColors.mutedStrong);
    });
  });

  group('SettingsScreen section grouping (R6 — U-15 ledger)', () {
    void pumpTall(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('section headers render uppercase labelSmall mutedStrong '
        '(F18 ADAPTED: the Juega grouping voice, Samay sharpness)', (tester) async {
      pumpTall(tester);
      await tester.pumpWidget(_wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      final appearance = tester.widget<Text>(find.text('APARIENCIA'));
      expect(appearance.style?.color, AppColors.mutedStrong,
          reason: '§2.4 — section headers are AA mutedStrong, never muted');
      expect(appearance.style?.fontFamily, AppTypography.inter);
      expect(appearance.style?.fontSize, 10,
          reason: '§3.3 — the labelSmall overline role');

      final account = tester.widget<Text>(find.text('CUENTA'));
      expect(account.style?.color, AppColors.mutedStrong);
    });

    testWidgets('rows group into two VCard sections; the danger pair closes '
        'the account card; the version footer stays outside', (tester) async {
      pumpTall(tester);
      await tester.pumpWidget(_wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.byType(VCard), findsNWidgets(2),
          reason: 'R6 — appearance + account groups (N2: sharp VCard '
              'hairlines, no Juega glass)');
      expect(
        find.descendant(
          of: find.byType(VCard).first,
          matching: find.byType(SegmentedButton<ThemeMode>),
        ),
        findsOneWidget,
        reason: 'the theme picker lives in the appearance card',
      );

      final accountCard = find.byType(VCard).last;
      expect(
        find.descendant(
          of: accountCard,
          matching: find.text('Eliminar mi cuenta'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: accountCard, matching: find.text('Cerrar sesión')),
        findsOneWidget,
        reason: 'R7 — the danger pair (delete + sign out) closes the account '
            'section',
      );
      expect(
        find.descendant(
          of: find.byType(VCard),
          matching: find.text('Samay v1.0.0'),
        ),
        findsNothing,
        reason: 'R10 — the version footer stays outside the cards',
      );
    });

    testWidgets('theme picker options + version footer stay as-is '
        '(R10 explicit keep)', (tester) async {
      pumpTall(tester);
      await tester.pumpWidget(_wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Oscuro'), findsOneWidget);
      expect(find.text('Sistema'), findsOneWidget);
      expect(
        find.byType(SegmentedButton<ThemeMode>),
        findsOneWidget,
        reason: 'R10 — the SegmentedButton (≥ Juega\'s cycling row) survives '
            'the grouping',
      );
      expect(find.text('Samay v1.0.0'), findsOneWidget);
    });
  });

  group('ProfileScreen empty groups voice (R9 — U-15 ledger)', () {
    void pumpTall(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('empty groups render the VEmptyView icon + title + hint',
        (tester) async {
      pumpTall(tester);
      await tester.pumpWidget(_wrap(
        const ProfileScreen(),
        overrides: _profileOverrides(groups: const []),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(VEmptyView), findsOneWidget,
          reason: 'R9 — the 60px bare Text becomes the F2 voice '
              '(icon + title + hint)');
      expect(
        find.descendant(
          of: find.byType(VEmptyView),
          matching: find.byIcon(Icons.group_outlined),
        ),
        findsOneWidget,
      );
      expect(find.text('No perteneces a ningún grupo aún'), findsOneWidget);
      expect(
        find.text('Crea o únete a un grupo para verlo aquí.'),
        findsOneWidget,
      );
    });

    testWidgets('with groups, no VEmptyView renders', (tester) async {
      pumpTall(tester);
      await tester.pumpWidget(_wrap(
        const ProfileScreen(),
        overrides: _profileOverrides(groups: const [
          {'id': 'g1', 'name': 'Fiesta Club', 'group_shards': 42},
        ]),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(VEmptyView), findsNothing);
    });
  });

  group('PublicProfileScreen (§5.1/§3.2/§5.9 — U-09 ledger)', () {
    Widget pumpPublic({bool withProfile = false}) {
      final overrides = <Override>[];
      if (withProfile) {
        final friends = _FakeFriendsRepository();
        when(() => friends.getUserProfile(_userId)).thenAnswer(
          (_) async => const UserProfile(
            id: _userId,
            username: 'dana',
            bio: 'hola mundo',
          ),
        );
        when(() => friends.getFriendshipDetail(_userId))
            .thenAnswer((_) async => null);
        when(() => friends.getBlockStatus(_userId))
            .thenAnswer((_) async => false);
        overrides.add(friendsRepositoryProvider.overrideWithValue(friends));
      }
      return _wrap(
        const PublicProfileScreen(userId: _userId),
        overrides: overrides,
      );
    }

    testWidgets('primary "Agregar amigo" action uses glowAccent filled',
        (tester) async {
      await tester.pumpWidget(pumpPublic());
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Agregar amigo'), findsOneWidget);
      final button = tester.widget<VButton>(find.byType(VButton));
      expect(button.variant, VButtonVariant.glow,
          reason: '§5.1 — the primary public-profile action is the glow '
              'accent (U-07 precedent: filled pink CTA = the brand moment)');
      expect(button.filled, isTrue);
    });

    testWidgets('header mirrors the profile avatar + Playfair username + '
        'mutedStrong handle/bio', (tester) async {
      await tester.pumpWidget(pumpPublic(withProfile: true));
      await tester.pumpAndSettle();

      final ring = _avatarRing(tester);
      expect((ring.decoration as BoxDecoration).color, AppColors.surfaceAlt);

      final username = tester.widget<Text>(find.text('dana'));
      expect(username.style?.fontFamily, AppTypography.playfair);
      expect(username.style?.fontSize, 28);

      // '@dana' renders twice — AppBar title + body handle — scope to the
      // ListView body so the AppBar title cannot satisfy the assertion.
      final handle = tester.widget<Text>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('@dana'),
        ),
      );
      expect(handle.style?.color, AppColors.mutedStrong);

      final bio = tester.widget<Text>(find.text('hola mundo'));
      expect(bio.style?.color, AppColors.mutedStrong);
    });

    testWidgets('shared-groups placeholder renders mutedStrong (§5.9)',
        (tester) async {
      await tester.pumpWidget(pumpPublic());
      await tester.pump(const Duration(seconds: 1));

      final empty = tester.widget<Text>(find.text('Sin grupos en común'));
      expect(empty.style?.color, AppColors.mutedStrong);
    });
  });

  group('DeleteAccountScreen (§5.1/§5.2 — U-09 ledger)', () {
    testWidgets('danger CTA renders glowAccent outlined (pink border, not '
        'filled)', (tester) async {
      await tester.pumpWidget(_wrap(const DeleteAccountScreen()));
      await tester.pumpAndSettle();

      final button = tester.widget<VButton>(find.byType(VButton));
      expect(button.variant, VButtonVariant.glow);
      expect(button.filled, isFalse,
          reason: '§5.1 glowAccent outline — the delete CTA is a danger '
              'accent, not a brand moment; disabled drops to muted');
    });

    testWidgets('confirm dialog danger action renders glowPink', (tester) async {
      await tester.pumpWidget(_wrap(const DeleteAccountScreen()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'USER@samay.test');
      await tester.pump();
      // `.last` on find.text('Eliminar cuenta') resolves to the AppBar title
      // (Scaffold traversal order), so target the CTA TextButton directly —
      // same pattern as delete_account_flow_test.
      await tester.tap(find.widgetWithText(TextButton, 'Eliminar cuenta'));
      await tester.pumpAndSettle();

      expect(find.text('¿Eliminar cuenta?'), findsOneWidget);
      final confirm = tester.widget<Text>(find.text('Eliminar'));
      expect(confirm.style?.color, AppColors.error,
          reason: 'never raw red on black (§5.2) — the danger confirm uses '
              'the error semantic');
    });
  });
}

/// Stub friends repository for the public-profile harness: returns a known
/// profile, no friendship row, not blocked — the add-friend primary state.
class _FakeFriendsRepository extends Mock implements FriendsRepository {}

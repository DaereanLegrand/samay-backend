import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/models/user_profile.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/repositories/chat_repository.dart';
import 'package:samay/core/repositories/friends_repository.dart';
import 'package:samay/core/repositories/repository_providers.dart';
import 'package:samay/core/router/main_shell.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/features/auth/screens/login_screen.dart';
import 'package:samay/features/chat/providers/chat_providers.dart';
import 'package:samay/features/chat/screens/chat_screen.dart';
import 'package:samay/features/cosmetics/providers/cosmetics_providers.dart';
import 'package:samay/features/cosmetics/screens/cosmetics_shop_screen.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/groups/providers/groups_providers.dart'
    as groups;
import 'package:samay/features/profile/providers/profile_providers.dart'
    as profile;
import 'package:samay/features/profile/screens/edit_profile_screen.dart';
import 'package:samay/features/profile/screens/profile_screen.dart';
import 'package:samay/features/profile/screens/public_profile_screen.dart';
import 'package:samay/features/profile/screens/settings_screen.dart';
import 'package:samay/features/shards/providers/shard_ledger_providers.dart';
import 'package:samay/features/shards/screens/shard_ledger_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/rank_badge.dart';
import 'package:samay/shared/widgets/v_badge.dart';
import 'package:samay/shared/widgets/v_shard_icon.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;

import '../support/fake_supabase_http.dart' as support;

/// U-26 accessibility semantic suite — DISCO-DESIGN-SYSTEM.md §7 contract.
///
/// Scope (per SC):
/// * **1.4.3** — the §2.4 muted-text rule: tab labels (informational text)
///   must resolve `mutedStrong` (7.37:1), never `muted` (3.66:1 fails AA at
///   normal size). Disabled/hint/icon usages of `muted` are exempt (asserted
///   as justified in the U-26 daily log, not here).
/// * **1.4.4** — text scaling is covered by `test/features/responsive_test.dart`
///   (18 screens at 1.5× on 320×568, U-19) — referenced, not duplicated.
/// * **2.3.3** — reduced motion is covered by the U-18 suites
///   (`v_breathing_glow_test`, `v_status_dot_test`, `v_tab_fade_test`,
///   `v_shimmer_test` — every ambient animation gates on
///   `MediaQuery.disableAnimationsOf`) — referenced, not duplicated.
/// * **2.4.3/2.4.7** — focus order is the natural single-column tree order
///   (pinned by the login tab-through test); button focus rings are the
///   Material α0.1 white overlay (theme `overlayColor`, §5.1) — visible on
///   black, verified in the daily log.
/// * **3.2.2** — no input toggles context without user action (OTP auto-verify
///   on the 6th digit is the standard 2FA pattern and requires a server
///   round-trip; audited in the daily log).
/// * **4.1.2** — names/roles/states: shell nav labels survive the hidden-label
///   theme, icon-only buttons expose tooltip labels, no-op controls render
///   disabled, decorative shard icons are excluded, badges/placeholders stay
///   labeled.
///
/// Semantics are off by default in widget tests — every test here calls
/// [WidgetTester.ensureSemantics].
const _userId = '11111111-1111-1111-1111-111111111111';

// ── Stub notifiers (fixtures mirror the real Supabase data shapes) ────────

class _StubAuthNotifier extends AuthNotifier {
  _StubAuthNotifier([this.initial = const AuthState(user: {'id': _userId})]);

  final AuthState initial;

  @override
  Future<AuthState> build() async => initial;
}

class _StubProfileNotifier extends profile.MyProfileNotifier {
  @override
  Future<Map<String, dynamic>?> build() async => {
    'username': 'dana',
    'bio': 'hola mundo',
    'personal_shards': 120,
    'preshards': 3,
  };
}

class _StubProfileGroupsNotifier extends profile.ProfileGroupsNotifier {
  @override
  Future<List<Map<String, dynamic>>> build() async => const [];
}

class _StubFriendRequestsNotifier extends FriendRequestsNotifier {
  @override
  Future<FriendRequestsData> build() async =>
      const FriendRequestsData(requests: [], names: {});
}

class _StubGroupInvitesNotifier extends groups.GroupInvitesNotifier {
  @override
  Future<List<Map<String, dynamic>>> build() async => const [];
}

class _StubShardLedgerNotifier extends ShardLedgerNotifier {
  @override
  Future<ShardLedgerData> build() async =>
      const ShardLedgerData(shards: [], preshards: []);
}

class _StubCosmeticsCatalogNotifier extends CosmeticsCatalogNotifier {
  @override
  Future<List<Map<String, dynamic>>> build() async => const [];
}

class _StubMyCosmeticsNotifier extends MyCosmeticsNotifier {
  @override
  Future<List<Map<String, dynamic>>> build() async => const [];
}

class _StubChatMessagesNotifier extends ChatMessagesNotifier {
  _StubChatMessagesNotifier(this.messages);

  final List<Map<String, dynamic>> messages;

  @override
  Future<ChatMessagesState> build(String arg) async => ChatMessagesState(
    messages: messages,
    hasMore: false,
    loadingOlder: false,
  );
}

class _MockFriendsRepository extends Mock implements FriendsRepository {}

class _MockChatRepository extends Mock implements ChatRepository {}

class _MockRealtimeService extends Mock implements RealtimeService {}

class _MockRealtimeChannel extends Mock implements RealtimeChannel {}

// ── Harness ───────────────────────────────────────────────────────────────

/// Active semantics handle — `ensureSemantics` handles must be disposed
/// inside the test body (the end-of-test verification runs before
/// `addTearDown`), so [_disposeSemantics] is called at the end of each test.
SemanticsHandle? _semanticsHandle;

void _disposeSemantics() {
  _semanticsHandle?.dispose();
  _semanticsHandle = null;
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const [],
  bool semantics = true,
}) async {
  if (semantics) {
    _semanticsHandle = tester.ensureSemantics();
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: SamayTheme.dark,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Reads the semantics flags of the first render object matching [finder]
/// (a scoped finder expected to match exactly one widget).
SemanticsNode _semanticsOf(WidgetTester tester, Finder finder) {
  return tester.getSemantics(finder);
}

// Modern flag reads — `SemanticsNode.hasFlag` is deprecated (3.32+); the
// `flagsCollection` API reports Tristate flags (isSelected/isEnabled) and
// plain bools (isButton).
bool _isButton(SemanticsNode node) =>
    node.getSemanticsData().flagsCollection.isButton;

bool _isSelected(SemanticsNode node) =>
    node.getSemanticsData().flagsCollection.isSelected == Tristate.isTrue;

/// Disabled controls carry `isEnabled = Tristate.isFalse`; elements without
/// an enabled state (plain text) report `Tristate.none`.
bool _isDisabled(SemanticsNode node) =>
    node.getSemanticsData().flagsCollection.isEnabled == Tristate.isFalse;

/// Asserts that [target]'s subtree currently holds the primary keyboard
/// focus (the focused widget is an inner `Focus` node of [target] — e.g.
/// `EditableText`'s focus inside a `TextField`).
void _expectFocusedWithin(WidgetTester tester, Finder target, String reason) {
  final focusContext = tester.binding.focusManager.primaryFocus?.context;
  expect(focusContext, isNotNull, reason: 'focus must be claimed: $reason');
  expect(
    find.ancestor(of: find.byWidget(focusContext!.widget), matching: target),
    findsWidgets,
    reason: 'focus must land inside $target: $reason',
  );
}

void main() {
  setUpAll(() => support.initSupabaseHarness(sessionEmail: 'user@samay.test'));

  group('1.4.3 — §2.4 muted-text rule on tab labels', () {
    testWidgets('shard ledger tab unselected labels are mutedStrong, never '
        'muted (3.66:1 < 4.5:1)', (tester) async {
      await _pump(
        tester,
        const ShardLedgerScreen(),
        overrides: [
          shardLedgerProvider.overrideWith(_StubShardLedgerNotifier.new),
          profile.myProfileProvider.overrideWith(_StubProfileNotifier.new),
        ],
      );

      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      expect(
        tabBar.unselectedLabelColor,
        AppColors.mutedStrong,
        reason:
            '§2.4: unselected tab labels are informational text at normal '
            'size — muted #666666 fails 1.4.3 (3.66:1)',
      );
      _disposeSemantics();
    });

    testWidgets('cosmetics shop tab unselected labels are mutedStrong, never '
        'muted', (tester) async {
      await _pump(
        tester,
        const CosmeticsShopScreen(),
        overrides: [
          cosmeticsCatalogProvider.overrideWith(
            _StubCosmeticsCatalogNotifier.new,
          ),
          myCosmeticsProvider.overrideWith(_StubMyCosmeticsNotifier.new),
          profile.myProfileProvider.overrideWith(_StubProfileNotifier.new),
        ],
      );

      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabBar.unselectedLabelColor, AppColors.mutedStrong);
      _disposeSemantics();
    });
  });

  group('4.1.2 — shell bottom-nav names/roles/states', () {
    Widget shell() => const MainShell(currentIndex: 0, child: SizedBox());

    testWidgets('nav items expose their localized labels even though the '
        'labels are visually hidden (showSelectedLabels: false — '
        'Visibility.maintain keeps semantics)', (tester) async {
      await _pump(
        tester,
        shell(),
        overrides: [
          friendRequestsProvider.overrideWith(_StubFriendRequestsNotifier.new),
          groups.groupInvitesProvider.overrideWith(
            _StubGroupInvitesNotifier.new,
          ),
        ],
      );

      for (final label in ['Feed', 'Social', 'Eventos', 'Notis', 'Perfil']) {
        expect(
          find.descendant(
            of: find.byType(BottomNavigationBar),
            matching: find.bySemanticsLabel(RegExp('^$label')),
          ),
          findsWidgets,
          reason:
              'nav item "$label" must be announced to screen readers '
              '(4.1.2 name) even with the labels hidden — the framework '
              'appends the "Pestaña N de 5" index label to the tile name',
        );
      }
      _disposeSemantics();
    });

    testWidgets('nav tiles are buttons and the active tile is selected', (
      tester,
    ) async {
      await _pump(
        tester,
        shell(),
        overrides: [
          friendRequestsProvider.overrideWith(_StubFriendRequestsNotifier.new),
          groups.groupInvitesProvider.overrideWith(
            _StubGroupInvitesNotifier.new,
          ),
        ],
      );

      // The nav bar contains framework-internal Semantics widgets too —
      // resolve each to its owning node and dedupe, then filter to the
      // button tiles (4.1.2 role) by their `isButton` flag.
      final nodes = <SemanticsNode>[];
      for (final e
          in find
              .descendant(
                of: find.byType(BottomNavigationBar),
                matching: find.byType(Semantics),
              )
              .evaluate()) {
        final node = tester.getSemantics(find.byWidget(e.widget));
        if (!nodes.contains(node)) nodes.add(node);
      }
      final buttonTiles = nodes.where(_isButton).toList();
      expect(
        buttonTiles,
        hasLength(5),
        reason: 'one button-semantics tile per nav item (4.1.2 role)',
      );
      expect(
        _isSelected(buttonTiles.first),
        isTrue,
        reason: 'the active tab (Feed) is the selected nav item',
      );
      expect(
        _isSelected(buttonTiles[1]),
        isFalse,
        reason: 'unselected tabs must not report selected (4.1.2 value)',
      );
      _disposeSemantics();
    });
  });

  group('4.1.2 — icon-only buttons expose labels', () {
    testWidgets('the profile settings gear announces "Configuración"', (
      tester,
    ) async {
      await _pump(
        tester,
        const ProfileScreen(),
        overrides: [
          profile.myProfileProvider.overrideWith(_StubProfileNotifier.new),
          profile.myGroupsProvider.overrideWith(_StubProfileGroupsNotifier.new),
        ],
      );

      // IconButton tooltips surface in the semantics `tooltip` field, which
      // iOS VoiceOver/TalkBack announce as the control's name (4.1.2).
      expect(
        tester.getSemantics(find.byType(IconButton)).getSemanticsData().tooltip,
        'Configuración',
        reason:
            'the AppBar settings gear is icon-only — its tooltip must be '
            'its accessibility name (4.1.2)',
      );
      _disposeSemantics();
    });

    testWidgets('the public-profile overflow menu announces "Más opciones"', (
      tester,
    ) async {
      final repo = _MockFriendsRepository();
      when(() => repo.getUserProfile('u1')).thenAnswer(
        (_) async => const UserProfile(id: 'u1', username: 'ana', bio: 'hola'),
      );
      when(() => repo.getFriendshipDetail('u1')).thenAnswer((_) async => null);
      when(() => repo.getBlockStatus('u1')).thenAnswer((_) async => false);
      await _pump(
        tester,
        const PublicProfileScreen(userId: 'u1'),
        overrides: [
          friendsRepositoryProvider.overrideWithValue(repo),
          authStateProvider.overrideWith(_StubAuthNotifier.new),
        ],
      );

      expect(
        tester
            .getSemantics(
              find.descendant(
                of: find.byType(PopupMenuButton<String>),
                matching: find.byType(IconButton),
              ),
            )
            .getSemanticsData()
            .tooltip,
        'Más opciones',
        reason:
            'the AppBar overflow menu is icon-only — its tooltip must be '
            'its accessibility name (4.1.2)',
      );
      _disposeSemantics();
    });
  });

  group('4.1.2 — no-op controls render disabled (U-23 F3/F4)', () {
    /// A public profile whose friendship fetch resolves to [detail] and
    /// whose block status is [blocked] (mocked repository).
    Future<void> pumpBlockedState(
      WidgetTester tester, {
      Map<String, dynamic>? detail,
      required bool blocked,
    }) async {
      final repo = _MockFriendsRepository();
      when(() => repo.getUserProfile('u1')).thenAnswer(
        (_) async => const UserProfile(id: 'u1', username: 'ana', bio: 'hola'),
      );
      when(
        () => repo.getFriendshipDetail('u1'),
      ).thenAnswer((_) async => detail);
      when(() => repo.getBlockStatus('u1')).thenAnswer((_) async => blocked);
      await _pump(
        tester,
        const PublicProfileScreen(userId: 'u1'),
        overrides: [
          friendsRepositoryProvider.overrideWithValue(repo),
          authStateProvider.overrideWith(_StubAuthNotifier.new),
        ],
      );
    }

    testWidgets('the blocked status button is disabled, not an enabled '
        'no-op', (tester) async {
      await pumpBlockedState(tester, detail: null, blocked: true);

      final button = find.ancestor(
        of: find.text('Bloqueado'),
        matching: find.byType(TextButton),
      );
      final data = _semanticsOf(tester, button);
      expect(
        _isDisabled(data),
        isTrue,
        reason:
            'the "Bloqueado" status readout is not an action — an enabled '
            'no-op button fails 4.1.2/2.1.1 (U-23 F3)',
      );
      expect(_isButton(data), isTrue);
      expect(_semanticsOf(tester, find.text('Bloqueado')).label, 'Bloqueado');
      _disposeSemantics();
    });

    testWidgets('the accepted-status button is disabled, not an enabled '
        'no-op', (tester) async {
      await pumpBlockedState(
        tester,
        detail: const {'id': 'f1', 'status': 'accepted', 'requester_id': 'x'},
        blocked: false,
      );

      final button = find.ancestor(
        of: find.text('Amigos'),
        matching: find.byType(TextButton),
      );
      expect(
        _isDisabled(_semanticsOf(tester, button)),
        isTrue,
        reason:
            'the "Amigos" status readout is not an action — an enabled '
            'no-op button fails 4.1.2/2.1.1 (U-23 F3)',
      );
      _disposeSemantics();
    });

    testWidgets('settings Notificaciones/Privacidad rows are enabled and '
        'actionable (R2 — real navigation, not placeholders)', (tester) async {
      await _pump(tester, const SettingsScreen());

      for (final label in ['Notificaciones', 'Privacidad']) {
        final tile = find.ancestor(
          of: find.text(label),
          matching: find.byType(ListTile),
        );
        final data = _semanticsOf(tester, tile);
        expect(
          _isDisabled(data),
          isFalse,
          reason:
              'R2 — the "$label" row navigates to a real screen; a disabled '
              'row would block the action (2.1.1/4.1.2)',
        );
        expect(
          _isButton(data),
          isTrue,
          reason:
              'R2 — the "$label" row is an enabled action with a '
              'destination (2.1.1/4.1.2)',
        );
      }
      _disposeSemantics();
    });

    testWidgets('edit-profile "Cambiar contraseña" is disabled', (
      tester,
    ) async {
      await _pump(tester, const EditProfileScreen());

      final button = find.ancestor(
        of: find.text('Cambiar contraseña'),
        matching: find.byType(TextButton),
      );
      expect(
        _isDisabled(_semanticsOf(tester, button)),
        isTrue,
        reason:
            'the password-change placeholder is a no-op — it must render '
            'disabled (U-23 F4, 4.1.2)',
      );
      _disposeSemantics();
    });
  });

  group('1.4.1/4.1.2 — decorative vs labeled', () {
    testWidgets('VShardIcon is decorative: the adjacent count text carries '
        'the meaning', (tester) async {
      await _pump(
        tester,
        const Scaffold(body: Row(children: [VShardIcon(), Text('42 shards')])),
      );

      expect(
        find.bySemanticsLabel('shards'),
        findsNothing,
        reason:
            'the gold diamond repeats the count text — it must not add a '
            'redundant "shards" node (1.4.1: the text is the signal)',
      );
      expect(find.bySemanticsLabel('42 shards'), findsOneWidget);
      _disposeSemantics();
    });

    testWidgets('badges expose their labels (VBadge/RankBadge)', (
      tester,
    ) async {
      await _pump(
        tester,
        const Scaffold(
          body: Column(
            children: [
              VBadge(label: 'promotor'),
              RankBadge(bracket: 'b90_100'),
            ],
          ),
        ),
      );

      expect(
        find.bySemanticsLabel('PROMOTOR'),
        findsOneWidget,
        reason:
            '§3.3 labelSmall renders uppercase — the badge name must '
            'be announced (4.1.2)',
      );
      expect(
        find.bySemanticsLabel('FULL VIBE'),
        findsOneWidget,
        reason: 'rank brackets are labels, not decoration',
      );
      _disposeSemantics();
    });

    testWidgets('the chat undecryptable placeholder is labeled', (
      tester,
    ) async {
      final repo = _MockChatRepository();
      final channel = _MockRealtimeChannel();
      when(() => channel.unsubscribe()).thenAnswer((_) async => 'ok');
      when(() => repo.subscribe(any(), any())).thenReturn(channel);
      when(() => repo.subscribeToMessageReads(any(), any())).thenReturn(channel);
      when(() => repo.subscribeToMessageDeletes(any(), any())).thenReturn(channel);
      when(() => repo.peerNeedsRekey(any())).thenAnswer((_) async => false);
      when(() => repo.fetchInbox()).thenAnswer((_) async => <Map<String, dynamic>>[]);
      when(() => repo.getReadReceiptsEnabled()).thenAnswer((_) async => true);
      when(() => repo.markMessagesRead(any())).thenAnswer((_) async {});
      when(() => repo.markChatRead(any())).thenAnswer((_) async {});
      await _pump(
        tester,
        const ChatScreen(chatId: 'c1'),
        overrides: [
          authStateProvider.overrideWith(_StubAuthNotifier.new),
          chatMessagesProvider.overrideWith(
            () => _StubChatMessagesNotifier(const [
              {
                'id': 'm1',
                'sender_id': 'u2',
                'content': null,
                'decryptFailed': true,
                'created_at': '2026-08-01T00:00:00Z',
              },
            ]),
          ),
          chatE2eeRepositoryProvider.overrideWithValue(repo),
          realtimeServiceProvider.overrideWithValue(_MockRealtimeService()),
        ],
      );

      expect(
        find.bySemanticsLabel('Mensaje no descifrable'),
        findsOneWidget,
        reason:
            'an undecryptable message must be announced as such — the '
            'placeholder text is the only content of that bubble (4.1.2)',
      );
      _disposeSemantics();
    });
  });

  group('2.4.3 — focus order', () {
    testWidgets('login fields and actions receive focus in natural tree '
        'order', (tester) async {
      await _pump(
        tester,
        const LoginScreen(),
        overrides: [authStateProvider.overrideWith(_StubAuthNotifier.new)],
      );
      // No autofocus on login: focus starts at the first focusable.
      final emailField = find.byType(TextField).at(0);
      final passwordField = find.byType(TextField).at(1);

      Future<void> expectFocused(Finder target, String reason) async {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        _expectFocusedWithin(tester, target, reason);
      }

      await expectFocused(
        emailField,
        'the email field is the first focusable in tree order',
      );
      await expectFocused(
        passwordField,
        'the password field follows the email field (natural column order)',
      );
      // The 'forgot password' TextButton sits between the fields and the CTA.
      await expectFocused(
        find.byType(TextButton),
        'the forgot-password link follows the fields',
      );
      // The sign-in CTA (glowAccent VButton → TextButton) is next.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final ctaAncestors = find.ancestor(
        of: find.byWidget(
          tester.binding.focusManager.primaryFocus!.context!.widget,
        ),
        matching: find.byType(TextButton),
      );
      expect(
        find.descendant(
          of: ctaAncestors,
          matching: find.text('Iniciar sesión'),
        ),
        findsOneWidget,
        reason: 'the primary CTA is next in traversal order',
      );
      _disposeSemantics();
    });
  });
}

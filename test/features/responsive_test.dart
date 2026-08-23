import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/models/event.dart';
import 'package:samay/core/models/group.dart';
import 'package:samay/core/models/user_profile.dart';
import 'package:samay/core/models/group_member.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/chat_service.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/features/auth/screens/age_gate_screen.dart';
import 'package:samay/features/auth/screens/banned_screen.dart';
import 'package:samay/features/auth/screens/forgot_password_screen.dart';
import 'package:samay/features/auth/screens/login_screen.dart';
import 'package:samay/features/auth/screens/otp_verification_screen.dart';
import 'package:samay/features/auth/screens/privacy_terms_screen.dart';
import 'package:samay/features/auth/screens/profile_setup_screen.dart';
import 'package:samay/features/auth/screens/signup_contact_screen.dart';
import 'package:samay/features/auth/screens/welcome_screen.dart';
import 'package:samay/features/chat/providers/chat_providers.dart';
import 'package:samay/features/chat/screens/chat_screen.dart';
import 'package:samay/features/feed/providers/feed_providers.dart';
import 'package:samay/features/feed/screens/feed_screen.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/friends/screens/friends_list_screen.dart';
import 'package:samay/features/groups/providers/groups_providers.dart'
    as groups;
import 'package:samay/features/groups/screens/group_detail_screen.dart';
import 'package:samay/features/profile/providers/profile_providers.dart'
    as profile;
import 'package:samay/features/profile/screens/delete_account_screen.dart';
import 'package:samay/features/profile/screens/profile_screen.dart';
import 'package:samay/features/profile/screens/settings_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;

import '../support/fake_supabase_http.dart' as support;

/// Responsive layout smoke (U-19, DESIGN.md §7.3).
///
/// Every key screen is pumped at **text scale 1.5 on a 320×568 logical
/// viewport** (the smallest mainstream phone; the Ahem test font renders
/// every glyph 1em wide, so this is *harsher* than any real device) and must
/// render without a single overflow/exception — `tester.takeException()`
/// must stay null. Screens are required to be scroll-safe (the OTP
/// `LayoutBuilder + SingleChildScrollView + ConstrainedBox(minHeight) +
/// IntrinsicHeight` pattern, U-07) or naturally scrollable — fixed-height
/// text containers and rigid Columns are the overflow drivers this smoke
/// exists to catch.
///
/// Fixtures mirror the real Supabase data shapes (AGENT-RULES §0.6).
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
  Future<List<Map<String, dynamic>>> build() async => const [
        {
          'id': 'g1',
          'name': 'Fiesta Club',
          'group_shards': 42,
        },
      ];
}



class _StubGroupDetailNotifier extends groups.GroupDetailNotifier {
  @override
  Future<Group?> build(String arg) async => Group(
        id: arg,
        name: 'Fiesta Club Disco Nights',
        description: 'La mejor fiesta de la ciudad con luces disco.',
        sizeTier: 'large',
        rankBracket: 'b0_20',
        groupShards: 42,
      );
}

class _StubGroupMembersNotifier extends groups.GroupMembersNotifier {
  @override
  Future<List<GroupMember>> build(String arg) async => [
        GroupMember(
          id: 'gm-1',
          groupId: '',
          userId: '11111111-1111-1111-1111-111111111111',
          role: 'promotor',
          joinedAt: DateTime(2026),
          users: const {'username': 'dana'},
        ),
      ];
}

class _StubContributionsNotifier extends groups.GroupContributionsNotifier {
  @override
  Future<groups.GroupContributionsData> build(String arg) async =>
      const groups.GroupContributionsData(contributors: [], myContribution: 0);
}

class _StubFriendsListNotifier extends FriendsListNotifier {
  @override
  Future<List<UserProfile>> build() async => const [
        UserProfile(id: 'u1', username: 'dana'),
        UserProfile(id: 'u2', username: 'leo'),
      ];
}

class _StubFeedNotifier extends FeedNotifier {
  @override
  Future<List<Event>> build() async => [
        Event(
          id: 'e1',
          name: 'Fiesta de apertura del club nocturno',
          type: 'juerga',
          status: 'upcoming',
          startsAt: DateTime(2026, 9, 15, 22),
          endsAt: DateTime(2026, 9, 16, 2),
          locationName: 'Av. Larco 123, Miraflores',
          featured: true,
        ),
        Event(
          id: 'e2',
          name: 'Sesión de vinilos',
          type: 'tono',
          status: 'upcoming',
          startsAt: DateTime(2026, 9, 20, 20),
          endsAt: DateTime(2026, 9, 20, 23),
          locationName: 'Bar El Dado',
        ),
      ];
}

class _StubChatMessagesNotifier extends ChatMessagesNotifier {
  @override
  Future<ChatMessagesState> build(String arg) async => ChatMessagesState(
        messages: const [
          {
            'id': 'm1',
            'sender_id': 'u2',
            'content': 'Nos vemos a las 10 en la entrada.',
            'media_url': null,
            'created_at': '2026-08-01T00:00:00Z',
          },
          {
            'id': 'm2',
            'sender_id': _userId,
            'content': 'Perfecto, llevo las entradas.',
            'media_url': null,
            'created_at': '2026-08-01T00:01:00Z',
          },
        ],
        hasMore: false,
        loadingOlder: false,
      );

  @override
  Future<void> send(String chatId, String text) async {}

  @override
  Future<void> loadOlder() async {}
}

class _MockChatService extends Mock implements ChatService {}

class _MockRealtimeService extends Mock implements RealtimeService {}

class _MockRealtimeChannel extends Mock implements RealtimeChannel {}

const _userId = '11111111-1111-1111-1111-111111111111';

/// The U-19 smoke harness: a 320×568 logical viewport (smallest mainstream
/// phone), text scale 1.5 (§7.3 — the app must tolerate the 1.0–2.0 range),
/// the real Samay theme + es localization, and [overrides] injected.
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const [],
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
      child: ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: SamayTheme.dark,
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: child,
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

/// Unmounts the tree (the OTP screen's 1s cooldown timer needs `dispose`).
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  setUpAll(() => support.initSupabaseHarness(sessionEmail: 'user@samay.test'));

  group('auth funnel at 1.5x on 320×568 (§7.3)', () {
    testWidgets('welcome renders without overflow', (tester) async {
      await _pump(tester, const WelcomeScreen());
      expect(tester.takeException(), isNull);
    });

    testWidgets('login renders without overflow', (tester) async {
      await _pump(tester, const LoginScreen(), overrides: [
        authStateProvider.overrideWith(_StubAuthNotifier.new),
      ]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('signup renders without overflow', (tester) async {
      await _pump(tester, const SignupContactScreen(), overrides: [
        authStateProvider.overrideWith(_StubAuthNotifier.new),
      ]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('otp renders without overflow (scroll-safe body)', (
      tester,
    ) async {
      await _pump(
        tester,
        const OtpVerificationScreen(email: 'a@b.com', password: 'secret1'),
        overrides: [authStateProvider.overrideWith(_StubAuthNotifier.new)],
        settle: false,
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });

    testWidgets('age_gate renders without overflow', (tester) async {
      await _pump(tester, const AgeGateScreen(email: 'test@test.com'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('privacy_terms renders without overflow', (tester) async {
      await _pump(
        tester,
        const PrivacyTermsScreen(email: 'a@b.com', dateOfBirth: '2000-01-15'),
      );
      final ex = tester.takeException();
      if (ex != null) debugDumpRenderTree();
      expect(ex, isNull);
    });

    testWidgets('profile_setup renders without overflow', (tester) async {
      await _pump(
        tester,
        const ProfileSetupScreen(email: 'a@b.com', dateOfBirth: '2000-01-15'),
        overrides: [authStateProvider.overrideWith(_StubAuthNotifier.new)],
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('banned renders without overflow with a long reason', (
      tester,
    ) async {
      await _pump(
        tester,
        const BannedScreen(),
        overrides: [
          authStateProvider.overrideWith(
            () => _StubAuthNotifier(
              const AuthState(
                banned: true,
                banReason:
                    'Vulneración de los términos de servicio: contenido '
                    'inapropiado repetido durante varias semanas.',
              ),
            ),
          ),
        ],
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('forgot_password renders without overflow (scroll-safe '
        'body)', (tester) async {
      await _pump(tester, const ForgotPasswordScreen(), overrides: [
        authStateProvider.overrideWith(_StubAuthNotifier.new),
      ]);
      expect(tester.takeException(), isNull);
    });
  });

  group('profile feature at 1.5x on 320×568 (§7.3)', () {
    testWidgets('profile renders without overflow (incl. the groups '
        'section)', (tester) async {
      await _pump(tester, const ProfileScreen(), overrides: [
        profile.myProfileProvider.overrideWith(_StubProfileNotifier.new),
        profile.myGroupsProvider.overrideWith(_StubProfileGroupsNotifier.new),
      ]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('settings renders without overflow', (tester) async {
      await _pump(tester, const SettingsScreen());
      expect(tester.takeException(), isNull);
    });

    testWidgets('delete_account renders without overflow', (tester) async {
      await _pump(tester, const DeleteAccountScreen());
      expect(tester.takeException(), isNull);
    });
  });

  group('groups feature at 1.5x on 320×568 (§7.3)', () {
    testWidgets('group_detail renders without overflow (hero header + CTA '
        'row)', (tester) async {
      await _pump(
        tester,
        const GroupDetailScreen(groupId: 'g1'),
        overrides: [
          groups.groupDetailProvider.overrideWith(_StubGroupDetailNotifier.new),
          groups.groupMembersProvider.overrideWith(_StubGroupMembersNotifier.new),
          groups.contributionsProvider.overrideWith(_StubContributionsNotifier.new),
        ],
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('friends + chat + feed + coming-soon at 1.5x on 320×568 (§7.3)', () {
    testWidgets('friends_list renders without overflow', (tester) async {
      await _pump(tester, const FriendsListScreen(), overrides: [
        friendsListProvider.overrideWith(_StubFriendsListNotifier.new),
      ]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('chat renders without overflow (bubbles + composer)', (
      tester,
    ) async {
      final chatService = _MockChatService();
      final channel = _MockRealtimeChannel();
      when(() => chatService.subscribeToMessages(any(), any()))
          .thenReturn(channel);
      when(() => chatService.subscribeToMessageReads(any(), any()))
          .thenReturn(channel);
      when(() => chatService.subscribeToMessageDeletes(any(), any()))
          .thenReturn(channel);
      when(() => chatService.peerNeedsRekey(any())).thenAnswer((_) async => false);
      when(() => channel.unsubscribe()).thenAnswer((_) => Future.value('ok'));
      await _pump(
        tester,
        const ChatScreen(chatId: 'c1'),
        overrides: [
          authStateProvider.overrideWith(_StubAuthNotifier.new),
          chatMessagesProvider.overrideWith(_StubChatMessagesNotifier.new),
          chatE2eeServiceProvider.overrideWithValue(chatService),
          realtimeServiceProvider.overrideWithValue(_MockRealtimeService()),
        ],
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('feed renders without overflow (hero + radius chips + '
        'carousel + cards)', (tester) async {
      await _pump(tester, const FeedScreen(), overrides: [
        feedProvider.overrideWith(_StubFeedNotifier.new),
        feedRadiusOptionsProvider.overrideWithValue(
          const [5, 20, 50, kFeedRadiusAnywhereKm],
        ),
      ]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('settings renders without overflow (menu rows + header)',
        (tester) async {
      await _pump(tester, const SettingsScreen());
      expect(tester.takeException(), isNull);
    });
  });
}

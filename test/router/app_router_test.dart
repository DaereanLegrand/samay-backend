import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/config/feature_flags.dart';
import 'package:samay/core/models/event_photo.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/config_provider.dart';
import 'package:samay/core/router/app_router.dart';
import 'package:samay/core/router/route_extras.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/shared/widgets/route_error_screen.dart';
import 'package:samay/features/auth/screens/age_gate_screen.dart';
import 'package:samay/features/auth/screens/login_screen.dart';
import 'package:samay/features/auth/screens/otp_verification_screen.dart';
import 'package:samay/features/auth/screens/privacy_terms_screen.dart';
import 'package:samay/features/auth/screens/profile_setup_screen.dart';
import 'package:samay/features/auth/screens/signup_contact_screen.dart';
import 'package:samay/features/chat/screens/chat_screen.dart';
import 'package:samay/features/events/screens/create_event_screen.dart';
import 'package:samay/features/events/screens/event_detail_screen.dart';
import 'package:samay/features/events/screens/event_edit_screen.dart';
import 'package:samay/features/events/providers/events_providers.dart';
import 'package:samay/features/feed/screens/feed_screen.dart';
import 'package:samay/features/friends/screens/blocked_users_screen.dart';
import 'package:samay/features/friends/screens/friends_list_screen.dart';
import 'package:samay/features/friends/screens/requests_screen.dart';
import 'package:samay/features/friends/screens/search_screen.dart';
import 'package:samay/features/groups/screens/create_group_screen.dart';
import 'package:samay/features/groups/screens/donate_shards_screen.dart';
import 'package:samay/features/groups/screens/group_detail_screen.dart';
import 'package:samay/features/groups/screens/group_members_screen.dart';
import 'package:samay/features/groups/screens/invite_screen.dart';
import 'package:samay/features/groups/screens/leaderboard_screen.dart';
import 'package:samay/features/groups/screens/my_groups_screen.dart';
import 'package:samay/features/minigames/providers/minigames_providers.dart';
import 'package:samay/features/minigames/screens/minigames_screen.dart';
import 'package:samay/features/notifications/screens/notification_center_screen.dart';
import 'package:samay/features/party_finder/providers/party_finder_providers.dart';
import 'package:samay/features/party_finder/screens/party_finder_screen.dart';
import 'package:samay/features/photos/screens/photo_gallery_screen.dart';
import 'package:samay/features/photos/providers/photos_providers.dart';
import 'package:samay/features/profile/screens/delete_account_screen.dart';
import 'package:samay/features/profile/screens/edit_profile_screen.dart';
import 'package:samay/features/profile/screens/profile_screen.dart';
import 'package:samay/features/profile/screens/public_profile_screen.dart';
import 'package:samay/features/profile/screens/settings_screen.dart';
import 'package:samay/features/qr/screens/attendance_qr_screen.dart';
import 'package:samay/features/qr/providers/qr_providers.dart';
import 'package:samay/features/qr/screens/qr_scanner_screen.dart';
import 'package:samay/features/shards/providers/shard_ledger_providers.dart';
import 'package:samay/features/shards/screens/shard_ledger_screen.dart';
import 'package:samay/features/subscriptions/screens/paywall_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/v_coming_soon.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/fake_config_provider.dart';

const _eventId = '11111111-1111-1111-1111-111111111111';
const _groupId = '22222222-2222-2222-2222-222222222222';
const _chatId = '33333333-3333-3333-3333-333333333333';
const _token = '44444444-4444-4444-4444-444444444444';

Map<String, dynamic> _event() => {
      'id': _eventId,
      'name': 'Rave en el garaje',
      'description': 'La mejor fiesta del barrio',
      'type': 'juerga',
      'status': 'upcoming',
      'created_by_user_id': _eventId,
      'group_id': null,
      'location_name': 'Av. Los Aromos 123',
      'starts_at': DateTime(2026, 5, 15, 21).toIso8601String(),
      'ends_at': DateTime(2026, 5, 16, 2).toIso8601String(),
      'join_mode': 'open',
      'preshards_pool': 500,
      'preshards_distributed': false,
      'preshards_cap_per_user': null,
      'preshards_remainder_action': 'return',
      'dynamic_qr_enabled': true,
      'invite_token': 'invite-token',
      'cover_url': null,
      'featured': false,
      'created_at': DateTime(2026, 5, 10).toIso8601String(),
      'updated_at': DateTime(2026, 5, 10).toIso8601String(),
    };

class _FakeEventDetailNotifier extends EventDetailNotifier {
  @override
  Future<Map<String, dynamic>> build(String arg) async => _event();
}

class _FakeEventPromotoresNotifier extends EventPromotoresNotifier {
  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => [
        {
          'id': 'promo-1',
          'event_id': _eventId,
          'user_id': _eventId,
          'role': 'promotor',
          'preshards_contributed': 500,
          'added_at': DateTime(2026, 5, 10).toIso8601String(),
          'users': {'username': 'ana'},
        },
      ];
}

class _FakeMyEventInviteNotifier extends MyEventInviteNotifier {
  @override
  Future<Map<String, dynamic>?> build(String arg) async => null;
}

class _MemoryStorage extends LocalStorage {
  String? _token;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async => _token != null;

  @override
  Future<String?> accessToken() async => _token;

  @override
  Future<void> persistSession(String persistSessionString) async {
    _token = persistSessionString;
  }

  @override
  Future<void> removePersistedSession() async {
    _token = null;
  }
}

class _MemoryAsyncStorage extends GotrueAsyncStorage {
  final Map<String, String> _items = {};

  @override
  Future<String?> getItem({required String key}) async => _items[key];

  @override
  Future<void> setItem({required String key, required String value}) async {
    _items[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async {
    _items.remove(key);
  }
}

class _FakeAuthNotifier extends AuthNotifier {
  /// Pins the fake identity as authenticated. With the AsyncNotifier pattern
  /// the fake pins its identity in `build()` (the real notifier's `build()`
  /// would resolve the initial session from Supabase); without the pin, the
  /// router's `refreshListenable` would bounce the app to login mid-test.
  bool _pinAuthenticated = true;

  @override
  Future<AuthState> build() async =>
      const AuthState(authenticated: true, hasProfile: true);

  /// Opts out of the pin so tests can simulate a sign-out and exercise the
  /// auth redirect.
  void allowSignOut() => _pinAuthenticated = false;

  @override
  set state(AsyncValue<AuthState> value) {
    if (_pinAuthenticated && value.valueOrNull?.authenticated != true) return;
    super.state = value;
  }
}

/// Party-finder providers pinned to inert values (I-60): the router tests
/// only assert which screen the route builds, never the provider stack — the
/// real notifiers would hit the network via UserService.
class _FakeDiscoveryOptInNotifier extends DiscoveryOptInNotifier {
  @override
  Future<bool> build() async => false;
}

class _FakePartyMatchesNotifier extends PartyMatchesNotifier {
  @override
  Future<List<Map<String, dynamic>>> build() async => const [];
}

/// QR-token provider pinned to "no token issued" (I-57): the router tests
/// only assert which screen the route builds — the real notifier would hit
/// the network via EventService.
class _FakeQrTokenNotifier extends MyQrTokenNotifier {
  @override
  Future<Map<String, dynamic>?> build(String arg) async => null;
}

/// Photos providers pinned to inert values (I-59): the router tests only
/// assert which screen the route builds — the real notifiers would hit the
/// network via MediaService/EventService.
class _FakeEventPhotosNotifier extends EventPhotosNotifier {
  @override
  Future<List<EventPhoto>> build(String eventId) async => const [];
}

/// Minigames provider pinned to an inert value (I-63): the router tests only
/// assert which screen the route builds — the real notifier would hit the
/// network via MinigameService.
class _FakeMinigameSessionsNotifier extends MinigameSessionsNotifier {
  @override
  Future<List<Map<String, dynamic>>> build(String groupId) async => const [];
}

/// Shard-ledger provider pinned to an inert value (I-64): the router tests
/// only assert which screen the route builds — the real notifier would hit
/// the network via ShardsService.
class _FakeShardLedgerNotifier extends ShardLedgerNotifier {
  @override
  Future<ShardLedgerData> build() async =>
      const ShardLedgerData(shards: [], preshards: []);
}

ProviderContainer _newContainer({
  AppFeatureFlags flags = const AppFeatureFlags(),
  bool qrProviders = false,
}) {
  final container = ProviderContainer(overrides: [
    authStateProvider.overrideWith(() => _FakeAuthNotifier()),
    featureFlagsProvider.overrideWithValue(flags),
    eventDetailProvider.overrideWith(_FakeEventDetailNotifier.new),
    eventPromotoresProvider.overrideWith(_FakeEventPromotoresNotifier.new),
    myEventInviteProvider.overrideWith(_FakeMyEventInviteNotifier.new),
    discoveryOptInProvider.overrideWith(_FakeDiscoveryOptInNotifier.new),
    partyMatchesProvider.overrideWith(_FakePartyMatchesNotifier.new),
    minigameSessionsProvider.overrideWith(_FakeMinigameSessionsNotifier.new),
    eventPhotosProvider.overrideWith(_FakeEventPhotosNotifier.new),
    shardLedgerProvider.overrideWith(_FakeShardLedgerNotifier.new),
    appConfigProvider.overrideWith(() => FakeAppConfigNotifier(const {})),
    if (qrProviders) ...[
      myQrTokenProvider.overrideWith(_FakeQrTokenNotifier.new),
      qrDisplayWindowProvider.overrideWith((ref) async => 15),
    ],
  ]);
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpRoute(
  WidgetTester tester,
  ProviderContainer container,
  String path, {
  Object? extra,
  // Some screens never settle under pumpAndSettle (I-57's QrScannerScreen
  // embeds the real MobileScanner platform view, whose controller keeps
  // scheduling frames) — bounded pumps then.
  bool settle = true,
}) async {
  final router = container.read(routerProvider);
  router.go(path, extra: extra);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  setUpAll(() async {
    await Supabase.initialize(
      url: 'http://127.0.0.1:54386',
      anonKey: 'test-anon-key',
      authOptions: FlutterAuthClientOptions(
        localStorage: _MemoryStorage(),
        pkceAsyncStorage: _MemoryAsyncStorage(),
        detectSessionInUri: false,
      ),
    );
  });

  group('AppRouter', () {
    test('routerProvider is defined', () {
      final container = _newContainer();
      expect(container.read(routerProvider), isNotNull);
    });

    group('coming soon routes', () {
      for (final (path, title) in [
        (RoutePaths.eventInvite(_eventId), 'Invitar'),
        (RoutePaths.eventPhotos(_eventId), 'Fotos'),
        (RoutePaths.eventCollage(_eventId), 'Collage'),
        (RoutePaths.createGroupEvent(_groupId), 'Crear evento'),
        (RoutePaths.qr(_eventId), 'QR'),
        (RoutePaths.scanner(_eventId), 'Esc\u00e1ner'),
        (RoutePaths.subscriptions, 'Suscripciones'),
        (RoutePaths.partyFinder, 'Party Finder'),
        (RoutePaths.cosmetics, 'Cosm\u00e9ticos'),
        (RoutePaths.minigames(_groupId), 'Juegos'),
      ]) {
        testWidgets('$path renders coming soon screen', (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, path);
          expect(find.byType(VComingSoonScreen), findsOneWidget);
          expect(find.text('Pr\u00f3ximamente'), findsOneWidget);
          expect(find.text(title), findsOneWidget);
        });
      }

      testWidgets('${RoutePaths.mainEvents} renders coming soon with bottom nav',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.mainEvents);
        expect(find.byType(VComingSoonScreen), findsOneWidget);
        expect(find.byType(BottomNavigationBar), findsOneWidget);
        expect(
          find.text('Los eventos de tus grupos aparecer\u00e1n aqu\u00ed pronto.'),
          findsOneWidget,
        );
      });

      testWidgets('${RoutePaths.mainNotifications} renders the notification center with bottom nav',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.mainNotifications);
        expect(find.byType(NotificationCenterScreen), findsOneWidget);
        expect(find.byType(VComingSoonScreen), findsNothing);
        expect(find.byType(BottomNavigationBar), findsOneWidget);
      });

      testWidgets('${RoutePaths.groupMembers(_groupId)} renders GroupMembersScreen',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.groupMembers(_groupId));
        expect(find.byType(GroupMembersScreen), findsOneWidget);
        expect(find.byType(VComingSoonScreen), findsNothing);
      });

      testWidgets(
          '${RoutePaths.eventInviteToken(_token)} resolves to the event detail route '
          '(shadowed by /event/:eventId — documented NAV ordering issue, Phase 05)',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.eventInviteToken(_token));
        expect(find.byType(EventDetailScreen), findsOneWidget);
        expect(find.byType(VComingSoonScreen), findsNothing);
      });
      testWidgets('${RoutePaths.chat(_chatId)} renders ChatScreen',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.chat(_chatId));
        expect(find.byType(ChatScreen), findsOneWidget);
        expect(find.byType(VComingSoonScreen), findsNothing);
      });
    });

    group('RoutePaths coherence', () {
      for (final (path, widget) in [
        (RoutePaths.mainFeed, FeedScreen),
        (RoutePaths.mainGroups, MyGroupsScreen),
        (RoutePaths.mainEvents, VComingSoonScreen),
        (RoutePaths.mainNotifications, NotificationCenterScreen),
        (RoutePaths.mainProfile, ProfileScreen),
        (RoutePaths.groupCreate, CreateGroupScreen),
        (RoutePaths.groupsLeaderboard, LeaderboardScreen),
        (RoutePaths.userSearch, SearchScreen),
        (RoutePaths.friendsRequests, RequestsScreen),
        (RoutePaths.friendsList, FriendsListScreen),
        (RoutePaths.blockedUsers, BlockedUsersScreen),
        (RoutePaths.subscriptions, VComingSoonScreen),
        (RoutePaths.partyFinder, VComingSoonScreen),
        (RoutePaths.cosmetics, VComingSoonScreen),
        (RoutePaths.shardsLedger, ShardLedgerScreen),
        (RoutePaths.minigames(_groupId), VComingSoonScreen),
        (RoutePaths.settings, SettingsScreen),
        (RoutePaths.deleteAccount, DeleteAccountScreen),
        (RoutePaths.profileEdit, EditProfileScreen),
        (RoutePaths.signup, SignupContactScreen),
        (RoutePaths.ageGate, AgeGateScreen),
        (RoutePaths.eventDetail(_eventId), EventDetailScreen),
        (RoutePaths.eventEdit(_eventId), EventEditScreen),
        (RoutePaths.eventInvite(_eventId), VComingSoonScreen),
        (RoutePaths.eventPhotos(_eventId), VComingSoonScreen),
        (RoutePaths.eventCollage(_eventId), VComingSoonScreen),
        (RoutePaths.eventInviteToken(_token), EventDetailScreen),
        (RoutePaths.createGroupEvent(_groupId), VComingSoonScreen),
        (RoutePaths.chat(_chatId), ChatScreen),
        (RoutePaths.qr(_eventId), VComingSoonScreen),
        (RoutePaths.scanner(_eventId), VComingSoonScreen),
        (RoutePaths.groupMembers(_groupId), GroupMembersScreen),
        (RoutePaths.donateToGroup(_groupId), DonateShardsScreen),
        (RoutePaths.inviteToGroup(_groupId), InviteScreen),
        (RoutePaths.userProfile(_eventId), PublicProfileScreen),
      ]) {
        testWidgets('$path resolves to a screen', (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, path);
          expect(find.byType(widget), findsOneWidget);
        });
      }

      testWidgets(
          '${RoutePaths.createGroupEvent(_groupId)} renders CreateEventScreen '
          'when the events flag is on (dark-first gating, I-54)', (tester) async {
        final container = _newContainer(flags: const AppFeatureFlags(events: true));
        await _pumpRoute(tester, container, RoutePaths.createGroupEvent(_groupId));
        expect(find.byType(CreateEventScreen), findsOneWidget);
        expect(find.byType(VComingSoonScreen), findsNothing);
      });

      testWidgets(
          '${RoutePaths.partyFinder} renders PartyFinderScreen when the '
          'partyFinder flag is on (dark-first gating, I-60)', (tester) async {
        final container = _newContainer(
          flags: const AppFeatureFlags(partyFinder: true),
        );
        await _pumpRoute(tester, container, RoutePaths.partyFinder);
        expect(find.byType(PartyFinderScreen), findsOneWidget);
        expect(find.byType(VComingSoonScreen), findsNothing);
      });

      testWidgets(
          '${RoutePaths.subscriptions} renders PaywallScreen when the '
          'subscriptions flag is on (dark-first gating, I-61)', (tester) async {
        final container = _newContainer(
          flags: const AppFeatureFlags(subscriptions: true),
        );
        await _pumpRoute(tester, container, RoutePaths.subscriptions);
        expect(find.byType(PaywallScreen), findsOneWidget);
        expect(find.byType(VComingSoonScreen), findsNothing);
      });

      testWidgets(
          '${RoutePaths.qr(_eventId)} renders AttendanceQrScreen when the qr '
          'flag is on (dark-first gating, I-57)', (tester) async {
        final container = _newContainer(
          flags: const AppFeatureFlags(qr: true),
          qrProviders: true,
        );
        await _pumpRoute(tester, container, RoutePaths.qr(_eventId));
        expect(find.byType(AttendanceQrScreen), findsOneWidget);
        expect(find.byType(VComingSoonScreen), findsNothing);
      });

      testWidgets(
          '${RoutePaths.eventPhotos(_eventId)} renders PhotoGalleryScreen '
          'when the photoUpload flag is on (dark-first gating, I-59)',
          (tester) async {
        final container = _newContainer(
          flags: const AppFeatureFlags(photoUpload: true),
        );
        await _pumpRoute(tester, container, RoutePaths.eventPhotos(_eventId));
        expect(find.byType(PhotoGalleryScreen), findsOneWidget);
        expect(find.byType(VComingSoonScreen), findsNothing);
      });

      testWidgets(
          '${RoutePaths.minigames(_groupId)} renders MinigamesScreen when the '
          'minigames flag is on (dark-first gating, I-63)', (tester) async {
        final container = _newContainer(
          flags: const AppFeatureFlags(minigames: true),
        );
        await _pumpRoute(tester, container, RoutePaths.minigames(_groupId));
        expect(find.byType(MinigamesScreen), findsOneWidget);
        expect(find.byType(VComingSoonScreen), findsNothing);
      });

      testWidgets(
          '${RoutePaths.scanner(_eventId)} renders QrScannerScreen when the '
          'qr flag is on (dark-first gating, I-57)', (tester) async {
        final container = _newContainer(
          flags: const AppFeatureFlags(qr: true),
          qrProviders: true,
        );
        await _pumpRoute(
          tester,
          container,
          RoutePaths.scanner(_eventId),
          settle: false,
        );
        expect(find.byType(QrScannerScreen), findsOneWidget);
        expect(find.byType(VComingSoonScreen), findsNothing);
      });

      testWidgets('${RoutePaths.welcome} redirects to the feed', (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.welcome);
        expect(find.byType(FeedScreen), findsOneWidget);
      });

      testWidgets('${RoutePaths.login} redirects to the feed', (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.login);
        expect(find.byType(FeedScreen), findsOneWidget);
      });

      testWidgets('${RoutePaths.verify} resolves with extra', (tester) async {
        final container = _newContainer();
        await _pumpRoute(
          tester,
          container,
          RoutePaths.verify,
          extra: const VerifyExtra(email: 'a@b.com', password: 'secret1'),
        );
        expect(find.byType(OtpVerificationScreen), findsOneWidget);
      });

      testWidgets('${RoutePaths.privacyTerms} resolves with extra', (tester) async {
        final container = _newContainer();
        await _pumpRoute(
          tester,
          container,
          RoutePaths.privacyTerms,
          extra: const PrivacyTermsExtra(email: 'a@b.com', dateOfBirth: '2000-01-01'),
        );
        expect(find.byType(PrivacyTermsScreen), findsOneWidget);
      });

      testWidgets('${RoutePaths.profileSetup} resolves with extra', (tester) async {
        final container = _newContainer();
        await _pumpRoute(
          tester,
          container,
          RoutePaths.profileSetup,
          extra: const ProfileSetupExtra(email: 'a@b.com', dateOfBirth: '2000-01-01'),
        );
        expect(find.byType(ProfileSetupScreen), findsOneWidget);
      });

      testWidgets('${RoutePaths.groupDetail(_groupId)} resolves to a screen',
          (tester) async {
        final container = _newContainer();
        final router = container.read(routerProvider);
        router.go(RoutePaths.groupDetail(_groupId));
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              locale: const Locale('es'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(GroupDetailScreen), findsOneWidget);
      });
    });

    group('route hardening (H-03/H-04/M-08/M-09)', () {
      testWidgets('${RoutePaths.groupDetail('')} renders RouteErrorScreen, no crash',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.groupDetail(''));
        expect(find.byType(RouteErrorScreen), findsOneWidget);
      });

      testWidgets('${RoutePaths.userProfile('')} renders RouteErrorScreen, no crash',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.userProfile(''));
        expect(find.byType(RouteErrorScreen), findsOneWidget);
      });

      testWidgets('${RoutePaths.verify} without extra renders RouteErrorScreen, no crash',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.verify);
        expect(find.byType(RouteErrorScreen), findsOneWidget);
        expect(find.byType(OtpVerificationScreen), findsNothing);
      });

      testWidgets('${RoutePaths.privacyTerms} without extra renders RouteErrorScreen, no crash',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.privacyTerms);
        expect(find.byType(RouteErrorScreen), findsOneWidget);
        expect(find.byType(PrivacyTermsScreen), findsNothing);
      });

      testWidgets('${RoutePaths.profileSetup} without extra renders RouteErrorScreen, no crash',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.profileSetup);
        expect(find.byType(RouteErrorScreen), findsOneWidget);
        expect(find.byType(ProfileSetupScreen), findsNothing);
      });

      testWidgets('${RoutePaths.ageGate} with a wrong-typed extra does not crash',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.ageGate, extra: 42);
        expect(find.byType(AgeGateScreen), findsOneWidget);
      });

      testWidgets('unknown route renders the error screen via errorBuilder',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, '/does/not/exist');
        expect(find.byType(RouteErrorScreen), findsOneWidget);
      });

      testWidgets('auth state change re-evaluates the redirect via refreshListenable',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.mainProfile);
        expect(find.byType(ProfileScreen), findsOneWidget);

        final notifier = container.read(authStateProvider.notifier) as _FakeAuthNotifier;
        notifier.allowSignOut();
        notifier.state = const AsyncData(AuthState());
        await tester.pumpAndSettle();

        expect(find.byType(LoginScreen), findsOneWidget);
        expect(find.byType(ProfileScreen), findsNothing);
      });
    });
  });
}

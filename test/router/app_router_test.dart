import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/app.dart';
import 'package:samay/core/config/feature_flags.dart';
import 'package:samay/core/models/event.dart';
import 'package:samay/core/models/event_photo.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/config_provider.dart';
import 'package:samay/core/router/app_router.dart';
import 'package:samay/core/router/route_extras.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/connectivity_service.dart';
import 'package:samay/shared/widgets/route_error_screen.dart';
import 'package:samay/features/auth/screens/age_gate_screen.dart';
import 'package:samay/features/auth/screens/forgot_password_screen.dart';
import 'package:samay/features/auth/screens/login_screen.dart';
import 'package:samay/features/auth/screens/otp_verification_screen.dart';
import 'package:samay/features/auth/screens/privacy_terms_screen.dart';
import 'package:samay/features/auth/screens/profile_setup_screen.dart';
import 'package:samay/features/auth/screens/signup_contact_screen.dart';
import 'package:samay/features/chat/screens/chat_screen.dart';
import 'package:samay/features/cosmetics/screens/cosmetics_shop_screen.dart';
import 'package:samay/features/events/screens/create_event_screen.dart';
import 'package:samay/features/events/screens/event_collage_screen.dart';
import 'package:samay/features/events/screens/event_detail_screen.dart';
import 'package:samay/features/events/screens/event_edit_screen.dart';
import 'package:samay/features/events/screens/my_events_screen.dart';
import 'package:samay/features/events/providers/events_providers.dart';
import 'package:samay/features/events/widgets/event_invite_route.dart';
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
import 'package:samay/features/social/screens/social_screen.dart';
import 'package:samay/features/social/screens/user_ranking_screen.dart';
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
import 'package:samay/shared/widgets/state_views.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/fake_config_provider.dart';

const _eventId = '11111111-1111-1111-1111-111111111111';
const _groupId = '22222222-2222-2222-2222-222222222222';
const _chatId = '33333333-3333-3333-3333-333333333333';
const _token = '44444444-4444-4444-4444-444444444444';

Event _event() => Event(
  id: _eventId,
  name: 'Rave en el garaje',
  description: 'La mejor fiesta del barrio',
  type: 'juerga',
  status: 'upcoming',
  createdByUserId: _eventId,
  locationName: 'Av. Los Aromos 123',
  startsAt: DateTime(2026, 5, 15, 21),
  endsAt: DateTime(2026, 5, 16, 2),
  joinMode: 'open',
  preshardsPool: 500,
);

class _FakeEventDetailNotifier extends EventDetailNotifier {
  @override
  Future<Event> build(String arg) async => _event();
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

/// Events-tab list provider pinned to an inert value (R1 events sweep): the
/// router tests only assert which screen the route builds — the real
/// notifier would hit the network via EventService.
class _FakeMyEventsNotifier extends MyEventsNotifier {
  @override
  Future<List<Event>> build() async => const [];
}

/// Invite-token resolution pinned to "no such token" (EINV, I-66): the
/// router tests only assert the [EventInviteRoute] builds — the real
/// notifier would hit the network via EventService.
class _FakeEventByInviteTokenNotifier extends EventByInviteTokenNotifier {
  @override
  Future<Event?> build(String arg) async => null;
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

  /// Profile-less variant (no-fallback policy 2026-08-13): an authenticated
  /// user without a profile row must NOT be redirected anywhere — the guard
  /// never navigates on `hasProfile`.
  final bool hasProfile;

  _FakeAuthNotifier({this.hasProfile = true});

  @override
  Future<AuthState> build() async =>
      AuthState(authenticated: true, hasProfile: hasProfile);

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
  bool hasProfile = true,
  List<Override> extras = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(
        () => _FakeAuthNotifier(hasProfile: hasProfile),
      ),
      featureFlagsProvider.overrideWithValue(flags),
      eventDetailProvider.overrideWith(_FakeEventDetailNotifier.new),
      eventPromotoresProvider.overrideWith(_FakeEventPromotoresNotifier.new),
      myEventInviteProvider.overrideWith(_FakeMyEventInviteNotifier.new),
      myEventsProvider.overrideWith(_FakeMyEventsNotifier.new),
      eventByInviteTokenProvider.overrideWith(
        _FakeEventByInviteTokenNotifier.new,
      ),
      discoveryOptInProvider.overrideWith(_FakeDiscoveryOptInNotifier.new),
      partyMatchesProvider.overrideWith(_FakePartyMatchesNotifier.new),
      minigameSessionsProvider.overrideWith(_FakeMinigameSessionsNotifier.new),
      eventPhotosProvider.overrideWith(_FakeEventPhotosNotifier.new),
      shardLedgerProvider.overrideWith(_FakeShardLedgerNotifier.new),
      myQrTokenProvider.overrideWith(_FakeQrTokenNotifier.new),
      qrDisplayWindowProvider.overrideWith((ref) async => 15),
      appConfigProvider.overrideWith(() => FakeAppConfigNotifier(const {})),
      ...extras,
    ],
  );
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

    group('live feature routes (R1 events sweep — no coming-soon screens)', () {
      for (final (path, widget) in [
        (RoutePaths.eventInvite(_eventId), EventInviteRoute),
        (RoutePaths.eventPhotos(_eventId), PhotoGalleryScreen),
        (RoutePaths.eventCollage(_eventId), EventCollageScreen),
        (RoutePaths.createGroupEvent(_groupId), CreateEventScreen),
        (RoutePaths.qr(_eventId), AttendanceQrScreen),
        (RoutePaths.partyFinder, PartyFinderScreen),
        (RoutePaths.cosmetics, CosmeticsShopScreen),
        (RoutePaths.minigames(_groupId), MinigamesScreen),
      ]) {
        testWidgets('$path renders the real screen', (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, path);
          expect(find.byType(widget), findsOneWidget);
        });
      }

      testWidgets(
        '${RoutePaths.mainEvents} renders MyEventsScreen with bottom nav',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, RoutePaths.mainEvents);
          expect(find.byType(MyEventsScreen), findsOneWidget);
          expect(find.byType(BottomNavigationBar), findsOneWidget);
          // The empty list state — real copy, never 'PRÓXIMAMENTE'.
          expect(find.text('Aún no tienes eventos'), findsOneWidget);
          expect(find.text('Crear evento'), findsOneWidget);
        },
      );

      testWidgets(
        '${RoutePaths.mainNotifications} renders the notification center with bottom nav',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, RoutePaths.mainNotifications);
          expect(find.byType(NotificationCenterScreen), findsOneWidget);
          expect(find.byType(VEmptyView), findsNothing);
          expect(find.byType(BottomNavigationBar), findsOneWidget);
        },
      );

      testWidgets(
        '${RoutePaths.groupMembers(_groupId)} renders GroupMembersScreen',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(
            tester,
            container,
            RoutePaths.groupMembers(_groupId),
          );
          expect(find.byType(GroupMembersScreen), findsOneWidget);
        },
      );

      testWidgets(
        '${RoutePaths.eventInviteToken(_token)} resolves to the event detail route '
        '(shadowed by /event/:eventId — documented NAV ordering issue, Phase 05)',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(
            tester,
            container,
            RoutePaths.eventInviteToken(_token),
          );
          expect(find.byType(EventDetailScreen), findsOneWidget);
          expect(find.byType(VEmptyView), findsNothing);
        },
      );
      testWidgets('${RoutePaths.chat(_chatId)} renders ChatScreen', (
        tester,
      ) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.chat(_chatId));
        expect(find.byType(ChatScreen), findsOneWidget);
        expect(find.byType(VEmptyView), findsNothing);
      });

      testWidgets(
        '${RoutePaths.chat(_chatId)} with the chat flag dark restores the '
        'neutral flag-gate kill-switch fallback (I-38/I-69)',
        (tester) async {
          final container = _newContainer(
            flags: const AppFeatureFlags(chat: false),
          );
          await _pumpRoute(tester, container, RoutePaths.chat(_chatId));
          expect(find.byType(VEmptyView), findsOneWidget);
          expect(find.byType(ChatScreen), findsNothing);
          expect(find.text('No disponible'), findsOneWidget);
        },
      );

      testWidgets(
        '${RoutePaths.mainEvents} with the events flag dark renders the '
        'neutral kill-switch fallback',
        (tester) async {
          final container = _newContainer(
            flags: const AppFeatureFlags(events: false),
          );
          await _pumpRoute(tester, container, RoutePaths.mainEvents);
          expect(find.byType(VEmptyView), findsOneWidget);
          expect(find.byType(MyEventsScreen), findsNothing);
          expect(find.text('No disponible'), findsOneWidget);
        },
      );

      testWidgets(
        '${RoutePaths.subscriptions} stays on the neutral flag-gate fallback '
        'while the flag is off (RevenueCat key pending, I-61)',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, RoutePaths.subscriptions);
          expect(find.byType(VEmptyView), findsOneWidget);
          expect(find.byType(PaywallScreen), findsNothing);
          expect(find.text('No disponible'), findsOneWidget);
        },
      );
    });

    group('RoutePaths coherence', () {
      for (final (path, widget) in [
        (RoutePaths.mainFeed, FeedScreen),
        (RoutePaths.mainGroups, SocialScreen),
        (RoutePaths.mainEvents, MyEventsScreen),
        (RoutePaths.mainNotifications, NotificationCenterScreen),
        (RoutePaths.mainProfile, ProfileScreen),
        (RoutePaths.groupCreate, CreateGroupScreen),
        (RoutePaths.groupsLeaderboard, LeaderboardScreen),
        (RoutePaths.userRanking, UserRankingScreen),
        (RoutePaths.userSearch, SearchScreen),
        (RoutePaths.friendsRequests, RequestsScreen),
        (RoutePaths.friendsList, FriendsListScreen),
        (RoutePaths.blockedUsers, BlockedUsersScreen),
        (RoutePaths.shardsLedger, ShardLedgerScreen),
        (RoutePaths.settings, SettingsScreen),
        (RoutePaths.deleteAccount, DeleteAccountScreen),
        (RoutePaths.profileEdit, EditProfileScreen),
        (RoutePaths.signup, SignupContactScreen),
        (RoutePaths.forgotPassword, ForgotPasswordScreen),
        (RoutePaths.ageGate, AgeGateScreen),
        (RoutePaths.eventDetail(_eventId), EventDetailScreen),
        (RoutePaths.eventEdit(_eventId), EventEditScreen),
        (RoutePaths.eventInvite(_eventId), EventInviteRoute),
        (RoutePaths.eventPhotos(_eventId), PhotoGalleryScreen),
        (RoutePaths.eventCollage(_eventId), EventCollageScreen),
        (RoutePaths.eventInviteToken(_token), EventDetailScreen),
        (RoutePaths.createGroupEvent(_groupId), CreateEventScreen),
        (RoutePaths.chat(_chatId), ChatScreen),
        (RoutePaths.qr(_eventId), AttendanceQrScreen),
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
        '${RoutePaths.partyFinder} renders PartyFinderScreen with the default '
        'flags (R1 events sweep flipped partyFinder live, I-60)',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, RoutePaths.partyFinder);
          expect(find.byType(PartyFinderScreen), findsOneWidget);
        },
      );

      testWidgets('${RoutePaths.subscriptions} renders PaywallScreen when the '
          'subscriptions flag is on (dark-first gating, I-61)', (tester) async {
        final container = _newContainer(
          flags: const AppFeatureFlags(subscriptions: true),
        );
        await _pumpRoute(tester, container, RoutePaths.subscriptions);
        expect(find.byType(PaywallScreen), findsOneWidget);
      });

      testWidgets(
        '${RoutePaths.qr(_eventId)} renders AttendanceQrScreen with the '
        'default flags (R1 events sweep flipped qr live, I-57)',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, RoutePaths.qr(_eventId));
          expect(find.byType(AttendanceQrScreen), findsOneWidget);
        },
      );

      testWidgets(
        '${RoutePaths.eventPhotos(_eventId)} renders PhotoGalleryScreen with '
        'the default flags (R1 events sweep flipped photoUpload live, I-59)',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, RoutePaths.eventPhotos(_eventId));
          expect(find.byType(PhotoGalleryScreen), findsOneWidget);
        },
      );

      testWidgets(
        '${RoutePaths.minigames(_groupId)} renders MinigamesScreen with the '
        'default flags (R1 events sweep flipped minigames live, I-63)',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, RoutePaths.minigames(_groupId));
          expect(find.byType(MinigamesScreen), findsOneWidget);
        },
      );

      testWidgets(
        '${RoutePaths.scanner(_eventId)} renders QrScannerScreen with the '
        'default flags (R1 events sweep flipped qr live, I-57)',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(
            tester,
            container,
            RoutePaths.scanner(_eventId),
            settle: false,
          );
          expect(find.byType(QrScannerScreen), findsOneWidget);
        },
      );

      testWidgets('${RoutePaths.welcome} redirects to the feed', (
        tester,
      ) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.welcome);
        expect(find.byType(FeedScreen), findsOneWidget);
      });

      testWidgets('${RoutePaths.login} redirects to the feed', (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.login);
        expect(find.byType(FeedScreen), findsOneWidget);
      });

      testWidgets('authenticated WITHOUT profile is sent to the age gate '
          '(funnel-completion gate — never the feed)', (tester) async {
        final container = _newContainer(hasProfile: false);
        await _pumpRoute(tester, container, RoutePaths.mainFeed);
        expect(find.byType(AgeGateScreen), findsOneWidget);
        expect(find.byType(FeedScreen), findsNothing);
        expect(find.byType(SignupContactScreen), findsNothing);
      });

      testWidgets('profile-less user on /login lands on the age gate, not the '
          'feed (funnel-completion gate)', (tester) async {
        final container = _newContainer(hasProfile: false);
        await _pumpRoute(tester, container, RoutePaths.login);
        expect(find.byType(AgeGateScreen), findsOneWidget);
        expect(find.byType(FeedScreen), findsNothing);
      });

      testWidgets('${RoutePaths.signup} stays reachable for a profile-less '
          'user (explicit request, no redirect)', (tester) async {
        final container = _newContainer(hasProfile: false);
        await _pumpRoute(tester, container, RoutePaths.signup);
        expect(find.byType(SignupContactScreen), findsOneWidget);
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

      testWidgets('${RoutePaths.privacyTerms} resolves with extra', (
        tester,
      ) async {
        final container = _newContainer();
        await _pumpRoute(
          tester,
          container,
          RoutePaths.privacyTerms,
          extra: const PrivacyTermsExtra(
            email: 'a@b.com',
            dateOfBirth: '2000-01-01',
          ),
        );
        expect(find.byType(PrivacyTermsScreen), findsOneWidget);
      });

      testWidgets('${RoutePaths.profileSetup} resolves with extra', (
        tester,
      ) async {
        final container = _newContainer();
        await _pumpRoute(
          tester,
          container,
          RoutePaths.profileSetup,
          extra: const ProfileSetupExtra(
            email: 'a@b.com',
            dateOfBirth: '2000-01-01',
          ),
        );
        expect(find.byType(ProfileSetupScreen), findsOneWidget);
      });

      testWidgets('${RoutePaths.groupDetail(_groupId)} resolves to a screen', (
        tester,
      ) async {
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
      testWidgets(
        '${RoutePaths.groupDetail('')} renders RouteErrorScreen, no crash',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, RoutePaths.groupDetail(''));
          expect(find.byType(RouteErrorScreen), findsOneWidget);
        },
      );

      testWidgets(
        '${RoutePaths.userProfile('')} renders RouteErrorScreen, no crash',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, RoutePaths.userProfile(''));
          expect(find.byType(RouteErrorScreen), findsOneWidget);
        },
      );

      testWidgets(
        '${RoutePaths.verify} without extra renders RouteErrorScreen, no crash',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, RoutePaths.verify);
          expect(find.byType(RouteErrorScreen), findsOneWidget);
          expect(find.byType(OtpVerificationScreen), findsNothing);
        },
      );

      testWidgets(
        '${RoutePaths.privacyTerms} without extra renders RouteErrorScreen, no crash',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, RoutePaths.privacyTerms);
          expect(find.byType(RouteErrorScreen), findsOneWidget);
          expect(find.byType(PrivacyTermsScreen), findsNothing);
        },
      );

      testWidgets(
        '${RoutePaths.profileSetup} without extra renders RouteErrorScreen, no crash',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, RoutePaths.profileSetup);
          expect(find.byType(RouteErrorScreen), findsOneWidget);
          expect(find.byType(ProfileSetupScreen), findsNothing);
        },
      );

      testWidgets(
        '${RoutePaths.ageGate} with a wrong-typed extra does not crash',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, RoutePaths.ageGate, extra: 42);
          expect(find.byType(AgeGateScreen), findsOneWidget);
        },
      );

      testWidgets('unknown route renders the error screen via errorBuilder', (
        tester,
      ) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, '/does/not/exist');
        expect(find.byType(RouteErrorScreen), findsOneWidget);
      });

      testWidgets(
        'auth state change re-evaluates the redirect via refreshListenable',
        (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, RoutePaths.mainProfile);
          expect(find.byType(ProfileScreen), findsOneWidget);

          final notifier =
              container.read(authStateProvider.notifier) as _FakeAuthNotifier;
          notifier.allowSignOut();
          notifier.state = const AsyncData(AuthState());
          await tester.pumpAndSettle();

          expect(find.byType(LoginScreen), findsOneWidget);
          expect(find.byType(ProfileScreen), findsNothing);
        },
      );
    });

    group('connectivity banner on shell routes (I-67 + U-08)', () {
      const offlineCopy =
          'Sin conexión — los datos podrían no estar actualizados';

      testWidgets('the app-level banner renders above the shell content '
          'when offline and hides when online', (tester) async {
        final controller = StreamController<bool>();
        addTearDown(controller.close);
        final container = _newContainer(
          extras: [
            connectivityServiceProvider.overrideWithValue(
              ConnectivityService(
                onConnectivityChanged: () => controller.stream,
              ),
            ),
          ],
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const SamayApp(),
          ),
        );
        await tester.pumpAndSettle();

        // The fake auth pins authenticated → the router redirects the initial
        // /login to /main/feed: the shell route with the bottom nav.
        expect(find.byType(BottomNavigationBar), findsOneWidget);

        controller.add(true);
        await tester.pumpAndSettle();
        expect(find.text(offlineCopy), findsNothing);

        controller.add(false);
        await tester.pumpAndSettle();
        expect(find.text(offlineCopy), findsOneWidget);
        expect(find.byIcon(Icons.wifi_off), findsOneWidget);
        expect(
          find.byType(BottomNavigationBar),
          findsOneWidget,
          reason: 'the banner overlays the shell — it must never replace it',
        );

        controller.add(true);
        await tester.pumpAndSettle();
        expect(find.text(offlineCopy), findsNothing);
      });
    });

    group('NAV-08 — tab routes use NoTransitionPage (U-18)', () {
      /// The go_router shell's own Navigator — the one whose pages are the
      /// tab screens (the root Navigator holds the shell + pushed routes).
      Navigator shellNavigator(WidgetTester tester) {
        return tester
            .widgetList<Navigator>(find.byType(Navigator))
            .firstWhere(
              (n) => n.pages.any((p) => p is NoTransitionPage),
              orElse: () => fail(
                'expected the shell Navigator to hold NoTransitionPage pages '
                '(NAV-08)',
              ),
            );
      }

      testWidgets('every tab route builds a NoTransitionPage and never a '
          'slide/zoom MaterialPage (NAV-08)', (tester) async {
        final container = _newContainer();
        for (final path in [
          RoutePaths.mainFeed,
          RoutePaths.mainGroups,
          RoutePaths.mainEvents,
          RoutePaths.mainNotifications,
          RoutePaths.mainProfile,
        ]) {
          await _pumpRoute(tester, container, path);
          final nav = shellNavigator(tester);
          expect(
            nav.pages.whereType<NoTransitionPage>(),
            isNotEmpty,
            reason: '$path must build a NoTransitionPage (NAV-08)',
          );
          expect(
            nav.pages.whereType<MaterialPage>(),
            isEmpty,
            reason: '$path must not build a slide-in MaterialPage (NAV-08)',
          );
        }
      });

      testWidgets('a tab switch swaps the page with no slide/zoom wrapper — '
          'the subtle motion is the 150ms VTabFade fade-in only', (
        tester,
      ) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, RoutePaths.mainFeed);

        await tester.tap(find.byIcon(Icons.group_outlined));
        await tester.pump();

        expect(
          find.byType(SocialScreen),
          findsOneWidget,
          reason: 'the incoming tab is already present after one frame',
        );
        expect(
          find.descendant(
            // Page-transition wrappers of the tab pages live BETWEEN the
            // shell Navigator and the page's own Scaffold. Scaffold's FAB
            // machinery also uses ScaleTransitions — but inside the page,
            // never as ancestors of the screen widget; and the ROOT
            // navigator's shell-page transition sits above the shell
            // Navigator. The intersection is therefore exactly the tab
            // page-transition wrappers — empty under NoTransitionPage.
            of: find.byWidget(shellNavigator(tester)),
            matching: find.ancestor(
              of: find.byType(SocialScreen),
              matching: find.byWidgetPredicate(
                (w) => w is SlideTransition || w is ScaleTransition,
              ),
            ),
          ),
          findsNothing,
          reason:
              'NoTransitionPage disposes the old tab instantly — no '
              'slide/zoom wrapper around the incoming one (NAV-08)',
        );
        expect(find.byType(BottomNavigationBar), findsOneWidget);
      });
    });
  });
}

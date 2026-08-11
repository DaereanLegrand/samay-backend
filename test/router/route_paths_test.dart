import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/router/route_paths.dart';

void main() {
  group('RoutePaths static constants', () {
    final constants = [
      RoutePaths.welcome,
      RoutePaths.login,
      RoutePaths.banned,
      RoutePaths.signup,
      RoutePaths.verify,
      RoutePaths.forgotPassword,
      RoutePaths.ageGate,
      RoutePaths.privacyTerms,
      RoutePaths.profileSetup,
      RoutePaths.authPrefix,
      RoutePaths.mainFeed,
      RoutePaths.mainGroups,
      RoutePaths.mainEvents,
      RoutePaths.mainNotifications,
      RoutePaths.mainProfile,
      RoutePaths.groupCreate,
      RoutePaths.groupsLeaderboard,
      RoutePaths.userSearch,
      RoutePaths.friendsRequests,
      RoutePaths.friendsList,
      RoutePaths.blockedUsers,
      RoutePaths.subscriptions,
      RoutePaths.partyFinder,
      RoutePaths.cosmetics,
      RoutePaths.shardsLedger,
      RoutePaths.settings,
      RoutePaths.deleteAccount,
      RoutePaths.profileEdit,
    ];

    test('exposes all 28 route constants used by the app', () {
      expect(constants, hasLength(28));
    });

    test('forgotPassword is the dedicated password-recovery route', () {
      expect(RoutePaths.forgotPassword, '/forgot-password');
    });

    test('every constant is non-empty and starts with /', () {
      for (final path in constants) {
        expect(path, isNotEmpty);
        expect(
          path.startsWith('/'),
          isTrue,
          reason: 'must start with "/": "$path"',
        );
      }
    });

    test('authPrefix keeps its trailing slash for startsWith checks', () {
      expect(RoutePaths.authPrefix, '/auth/');
    });
  });

  group('RoutePaths builders', () {
    test('eventDetail interpolates', () {
      expect(RoutePaths.eventDetail('e1'), '/event/e1');
    });

    test('eventEdit interpolates', () {
      expect(RoutePaths.eventEdit('e1'), '/event/e1/edit');
    });

    test('eventInvite interpolates', () {
      expect(RoutePaths.eventInvite('e1'), '/event/e1/invite');
    });

    test('eventPhotos interpolates', () {
      expect(RoutePaths.eventPhotos('e1'), '/event/e1/photos');
    });

    test('eventCollage interpolates', () {
      expect(RoutePaths.eventCollage('e1'), '/event/e1/collage');
    });

    test('eventInviteToken interpolates', () {
      expect(RoutePaths.eventInviteToken('t1'), '/event/t1');
    });

    test('groupDetail interpolates', () {
      expect(RoutePaths.groupDetail('g1'), '/group/g1');
    });

    test('groupMembers interpolates', () {
      expect(RoutePaths.groupMembers('g1'), '/group/g1/members');
    });

    test('donateToGroup interpolates', () {
      expect(RoutePaths.donateToGroup('g1'), '/group/g1/donate');
    });

    test('createGroupEvent interpolates', () {
      expect(RoutePaths.createGroupEvent('g1'), '/group/g1/create-event');
    });

    test('inviteToGroup interpolates', () {
      expect(RoutePaths.inviteToGroup('g1'), '/group/g1/invite');
    });

    test('chat interpolates', () {
      expect(RoutePaths.chat('c1'), '/chat/c1');
    });

    test('userProfile interpolates', () {
      expect(RoutePaths.userProfile('u1'), '/user/u1');
    });

    test('qr interpolates', () {
      expect(RoutePaths.qr('e1'), '/qr/e1');
    });

    test('scanner interpolates', () {
      expect(RoutePaths.scanner('e1'), '/scanner/e1');
    });

    test('minigames interpolates', () {
      expect(RoutePaths.minigames('g1'), '/minigames/g1');
    });
  });
}

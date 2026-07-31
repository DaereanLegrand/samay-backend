import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/router/app_router.dart';
import 'package:samay/features/groups/group_members_screen.dart';
import 'package:samay/shared/widgets/v_coming_soon.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

const _eventId = '11111111-1111-1111-1111-111111111111';
const _groupId = '22222222-2222-2222-2222-222222222222';
const _chatId = '33333333-3333-3333-3333-333333333333';
const _token = '44444444-4444-4444-4444-444444444444';

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
  _FakeAuthNotifier() : super() {
    state = const AuthState(authenticated: true, hasProfile: true);
  }
}

ProviderContainer _newContainer() {
  final container = ProviderContainer(overrides: [
    authStateProvider.overrideWith((ref) => _FakeAuthNotifier()),
  ]);
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpRoute(
  WidgetTester tester,
  ProviderContainer container,
  String path,
) async {
  final router = container.read(routerProvider);
  router.go(path);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await Supabase.initialize(
      url: 'http://localhost:54321',
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
        ('/event/$_eventId', 'Evento'),
        ('/event/$_eventId/edit', 'Editar evento'),
        ('/event/$_eventId/invite', 'Invitar'),
        ('/event/$_eventId/photos', 'Fotos'),
        ('/event/$_eventId/collage', 'Collage'),
        ('/group/$_groupId/create-event', 'Crear evento'),
        ('/chat/$_chatId', 'Chat'),
        ('/qr/$_eventId', 'QR'),
        ('/scanner/$_eventId', 'Esc\u00e1ner'),
        ('/subscriptions', 'Suscripciones'),
        ('/party-finder', 'Party Finder'),
      ]) {
        testWidgets('$path renders coming soon screen', (tester) async {
          final container = _newContainer();
          await _pumpRoute(tester, container, path);
          expect(find.byType(VComingSoonScreen), findsOneWidget);
          expect(find.text('Pr\u00f3ximamente'), findsOneWidget);
          expect(find.text(title), findsOneWidget);
        });
      }

      testWidgets('/main/events renders coming soon with bottom nav',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, '/main/events');
        expect(find.byType(VComingSoonScreen), findsOneWidget);
        expect(find.byType(BottomNavigationBar), findsOneWidget);
        expect(
          find.text('Los eventos de tus grupos aparecer\u00e1n aqu\u00ed pronto.'),
          findsOneWidget,
        );
      });

      testWidgets('/main/notifications renders coming soon with bottom nav',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, '/main/notifications');
        expect(find.byType(VComingSoonScreen), findsOneWidget);
        expect(find.byType(BottomNavigationBar), findsOneWidget);
        expect(
          find.text('Tus notificaciones aparecer\u00e1n aqu\u00ed pronto.'),
          findsOneWidget,
        );
      });

      testWidgets('/group/:groupId/members renders GroupMembersScreen',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, '/group/$_groupId/members');
        expect(find.byType(GroupMembersScreen), findsOneWidget);
        expect(find.byType(VComingSoonScreen), findsNothing);
      });

      testWidgets('/event/:inviteToken resolves to the event detail route',
          (tester) async {
        final container = _newContainer();
        await _pumpRoute(tester, container, '/event/$_token');
        expect(find.byType(VComingSoonScreen), findsOneWidget);
        expect(find.text('Evento'), findsOneWidget);
      });
    });
  });
}

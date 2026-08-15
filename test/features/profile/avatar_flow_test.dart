import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mocktail/mocktail.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/auth_service.dart';
import 'package:samay/core/services/media_service.dart';
import 'package:samay/core/services/permission_service.dart';
import 'package:samay/crypto/e2ee_key_store.dart';
import 'package:samay/features/chat/providers/chat_providers.dart';
import 'package:samay/core/services/user_service.dart';
import 'package:samay/features/profile/screens/edit_profile_screen.dart';
import 'package:samay/features/profile/providers/profile_providers.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/v_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// PRFL avatar-upload flow tests (I-36): the edit screen wires
/// PermissionService → gallery pick → MediaService.uploadUserAvatar →
/// UserService.updateAvatarUrl → myProfileProvider invalidation.
///
/// The pipeline runs through the real screen with every external seam faked:
/// the auth state comes from a mock [AuthService] via
/// [authServiceProvider], the upload/persist services are mocktail mocks via
/// their Riverpod providers, and the OS permission + image-picker plugins are
/// injected functions (both plugins cannot run in widget tests).

const _userId = '11111111-1111-1111-1111-111111111111';
const _avatarUrl = 'https://cdn.example/avatars/$_userId/123.png';

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

Future<void> _initFakeSupabase() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'http://127.0.0.1:54386',
    anonKey: 'test-anon-key',
    authOptions: FlutterAuthClientOptions(
      localStorage: _MemoryStorage(),
      pkceAsyncStorage: _MemoryAsyncStorage(),
      detectSessionInUri: false,
    ),
  );
}

class _MockAuthService extends Mock implements AuthService {}

class _MockMediaService extends Mock implements MediaService {}

class _MockUserService extends Mock implements UserService {}

class _StubProfileFetcher {
  _StubProfileFetcher(this._onFetch);

  final Future<Map<String, dynamic>?> Function() _onFetch;
  int calls = 0;

  Future<Map<String, dynamic>?> call() {
    calls++;
    return _onFetch();
  }
}

class _StubProfileNotifier extends MyProfileNotifier {
  _StubProfileNotifier(this.fetcher);

  final _StubProfileFetcher fetcher;

  @override
  Future<Map<String, dynamic>?> build() => fetcher.call();
}

class _Harness {
  _Harness({
    Map<String, dynamic>? profile,
    this.pickerResult = true,
    this.granted = true,
    this.uploadError,
  }) : profile = profile ??
            const {
              'username': 'dana',
              'bio': 'hola mundo',
              'personal_shards': 120,
              'preshards': 3,
            };

  final Map<String, dynamic> profile;
  final bool pickerResult;
  final bool granted;
  final Object? uploadError;

  late final _StubProfileFetcher fetcher = _StubProfileFetcher(() async => profile);
  late final _MockAuthService auth = _MockAuthService();
  late final _MockMediaService media = _MockMediaService();
  late final _MockUserService userService = _MockUserService();
  late final PermissionService permissions = PermissionService(
    request: (_) async => granted
        ? ph.PermissionStatus.granted
        : ph.PermissionStatus.denied,
  );
  late final GalleryPicker galleryPicker = pickerResult
      ? (_) async => XFile.fromData(
            Uint8List.fromList(<int>[1, 2, 3, 4]),
            name: 'avatar.png',
          )
      : (_) async => null;

  List<Override> get overrides => <Override>[
        myProfileProvider.overrideWith(() => _StubProfileNotifier(fetcher)),
        authServiceProvider.overrideWithValue(auth),
        mediaServiceProvider.overrideWithValue(media),
        userServiceProvider.overrideWithValue(userService),
        // E2EE isolation (2026-08-15): the auth restore's ownership guard
        // touches the key store — the secure store's platform channel does
        // not complete under testWidgets' FakeAsync. Memory twins keep the
        // profile tests hermetic (E2EE is not under test here).
        e2eeKeyStoreProvider.overrideWithValue(MemoryE2eeKeyStore()),
        e2eeSessionStoreProvider.overrideWithValue(MemoryE2eeSessionStore()),
      ];

  void stubAuth({String? email}) {
    when(() => auth.onAuthStateChange).thenAnswer((_) => const Stream.empty());
    when(() => auth.getCurrentUser())
        .thenReturn(<String, dynamic>{'id': _userId, 'email': email ?? 'a@b.com'});
    when(() => auth.userHasProfile(any())).thenAnswer((_) async => true);
  }

  void stubUpload() {
    when(() => media.uploadUserAvatar(any(), any())).thenAnswer(
      (_) async => uploadError != null ? throw uploadError! : _avatarUrl,
    );
    when(() => userService.updateAvatarUrl(any(), any()))
        .thenAnswer((_) async {});
  }

  Widget wrap(Widget child) => ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: child,
        ),
      );
}

void main() {
  setUpAll(() {
    _initFakeSupabase();
    registerFallbackValue(Uint8List(0));
  });

  group('EditProfileScreen avatar upload (PRFL gap — I-36)', () {
    testWidgets('full flow: permission → picker → upload → persist → '
        'invalidate provider → snackbar', (tester) async {
      final h = _Harness();
      h.stubAuth();
      h.stubUpload();
      await tester.pumpWidget(h.wrap(EditProfileScreen(
        permissions: h.permissions,
        galleryPicker: h.galleryPicker,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.camera_alt));
      // LUXE v2 (XL-08): the gold VAurora's 10s ambient drift keeps frames
      // scheduled — `pumpAndSettle` would advance the clock past the
      // snackbar's 4s auto-dismiss. Bounded pumps: the async upload chain
      // (all microtasks, no timers) completes, then the entrance plays.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      verify(() => h.media.uploadUserAvatar(_userId, any())).called(1);
      verify(() => h.userService.updateAvatarUrl(_userId, _avatarUrl))
          .called(1);
      expect(h.fetcher.calls, 2,
          reason: 'myProfileProvider must be invalidated after the update');
      final l10n = await AppLocalizations.delegate.load(const Locale('es'));
      expect(find.text(l10n.profileAvatarUpdatedSnack), findsOneWidget);
    });

    testWidgets('denied photo permission: rationale snackbar, nothing uploaded',
        (tester) async {
      final h = _Harness(granted: false);
      h.stubAuth();
      h.stubUpload();
      await tester.pumpWidget(h.wrap(EditProfileScreen(
        permissions: h.permissions,
        galleryPicker: h.galleryPicker,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.camera_alt));
      // Bounded pump (not pumpAndSettle — the aurora drift would outlive the
      // snackbar's 4s auto-dismiss; see the full-flow test note).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final l10n = await AppLocalizations.delegate.load(const Locale('es'));
      expect(find.text(l10n.permissionsPhotoRationale), findsOneWidget);
      verifyNever(() => h.media.uploadUserAvatar(any(), any()));
      verifyNever(() => h.userService.updateAvatarUrl(any(), any()));
      expect(h.fetcher.calls, 1);
    });

    testWidgets('cancelled picker: flow aborts before any upload',
        (tester) async {
      final h = _Harness(pickerResult: false);
      h.stubAuth();
      h.stubUpload();
      await tester.pumpWidget(h.wrap(EditProfileScreen(
        permissions: h.permissions,
        galleryPicker: h.galleryPicker,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.camera_alt));
      await tester.pumpAndSettle();

      verifyNever(() => h.media.uploadUserAvatar(any(), any()));
      expect(h.fetcher.calls, 1);
    });

    testWidgets('upload failure: error snackbar, no persist, no invalidation',
        (tester) async {
      final h = _Harness(uploadError: Exception('boom'));
      h.stubAuth();
      h.stubUpload();
      await tester.pumpWidget(h.wrap(EditProfileScreen(
        permissions: h.permissions,
        galleryPicker: h.galleryPicker,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.camera_alt));
      // Bounded pump (not pumpAndSettle — the aurora drift would outlive the
      // snackbar's 4s auto-dismiss; see the full-flow test note).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // I-08 maps raw exceptions to the generic server error — no internals.
      expect(
        find.text('Error del servidor. Intenta de nuevo.'),
        findsOneWidget,
      );
      verifyNever(() => h.userService.updateAvatarUrl(any(), any()));
      expect(h.fetcher.calls, 1);
    });

    testWidgets('shows an in-button spinner while the upload is in flight',
        (tester) async {
      final h = _Harness();
      h.stubAuth();
      final completer = Completer<String>();
      when(() => h.media.uploadUserAvatar(any(), any()))
          .thenAnswer((_) => completer.future);
      when(() => h.userService.updateAvatarUrl(any(), any()))
          .thenAnswer((_) async {});
      await tester.pumpWidget(h.wrap(EditProfileScreen(
        permissions: h.permissions,
        galleryPicker: h.galleryPicker,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.camera_alt));
      // Advance through the permission + picker microtasks, then the upload
      // blocks on the completer — the progress indicator must be visible.
      await tester.pump();
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      completer.complete(_avatarUrl);
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('renders the stored avatar when the profile has avatar_url',
        (tester) async {
      final h = _Harness(profile: const {
        'username': 'dana',
        'bio': 'hola mundo',
        'avatar_url': _avatarUrl,
        'personal_shards': 120,
        'preshards': 3,
      });
      h.stubAuth();
      h.stubUpload();
      await tester.pumpWidget(h.wrap(EditProfileScreen(
        permissions: h.permissions,
        galleryPicker: h.galleryPicker,
      )));
      await tester.pumpAndSettle();

      expect(find.byType(VNetworkImage), findsOneWidget);
      expect(find.byIcon(Icons.person), findsNothing);
    });
  });
}

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:samay/core/providers/config_provider.dart';
import 'package:samay/core/models/event.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/core/services/media_service.dart';
import 'package:samay/core/services/moderation_service.dart';
import 'package:samay/core/services/permission_service.dart';
import 'package:samay/features/events/providers/events_providers.dart';
import 'package:samay/features/photos/screens/photo_gallery_screen.dart';
import 'package:samay/features/photos/providers/photos_providers.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';
import 'package:samay/shared/widgets/state_views.dart';
import 'package:samay/shared/widgets/v_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../support/fake_config_provider.dart';
/// PHUP gallery tests (I-59): provider list/signed-url caching/like
/// optimistic+rollback/report/upload against fake services injected through
/// the service providers, plus the screen's grid/empty/error/upload/window
/// behaviors with an injectable picker + permission seam.

const _eventId = '66666666-6666-6666-6666-666666666666';
const _userId = '11111111-1111-1111-1111-111111111111';

Map<String, dynamic> _photoRow(
  String id, {
  String storagePath = 'e-1/photos/x.png',
  int likes = 0,
}) {
  return {
    'id': id,
    'event_id': _eventId,
    'uploaded_by_user_id': _userId,
    'storage_path': storagePath,
    'likes_count': likes,
    'reported': false,
    'created_at': '2026-08-01T00:00:00Z',
  };
}

Map<String, dynamic> _event({DateTime? endsAt}) => {
      'id': _eventId,
      'name': 'Rave en el garaje',
      'type': 'juerga',
      'status': 'live',
      'starts_at': DateTime(2026, 8, 9, 20).toIso8601String(),
      'ends_at':
          (endsAt ?? DateTime(2030, 1, 1)).toIso8601String(),
    };

/// Solid-color PNG (header-valid, tiny) for the upload flow: it passes
/// [ImageProcessor.compressBytes] unchanged (below the skip threshold).
Future<Uint8List> _tinyPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 80, 80),
    Paint()..color = const Color(0xFF4B8BBE),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(80, 80);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

class _FakeMediaService implements MediaService {
  _FakeMediaService({this.rows = const []});

  List<Map<String, dynamic>> rows;
  Object? uploadError;
  int signedUrlCalls = 0;
  int listCalls = 0;
  final List<Uint8List> uploaded = [];
  String? uploadedEventId;

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  GoTrueClient get auth => throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> listEventPhotos(String eventId) async {
    if (listError != null) throw listError!;
    listCalls++;
    return List.of(rows);
  }

  Object? listError;

  @override
  Future<String> getSignedPhotoUrl(String storagePath) async {
    signedUrlCalls++;
    return 'signed://$storagePath';
  }

  @override
  Future<void> uploadEventPhotoBytes(String eventId, Uint8List bytes) async {
    if (uploadError != null) throw uploadError!;
    uploadedEventId = eventId;
    uploaded.add(bytes);
  }

  @override
  Future<String> uploadGroupCover(Uint8List bytes) =>
      throw UnimplementedError();

  @override
  Future<String> uploadEventCover(Uint8List bytes) =>
      throw UnimplementedError();

  @override
  Future<String> uploadUserAvatar(String userId, Uint8List bytes) =>
      throw UnimplementedError();

  @override
  Future<void> uploadEventPhoto(String eventId, String filePath) =>
      throw UnimplementedError();
}

class _FakeEventService implements EventService {
  _FakeEventService({this.myLikes = const []});

  List<String> myLikes;
  Object? likeError;
  Completer<void>? likeGate;
  final List<String> liked = [];
  final List<String> unliked = [];

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  GoTrueClient get auth => throw UnimplementedError();

  @override
  Future<List<String>> getMyPhotoLikes(String eventId) async =>
      List.of(myLikes);

  @override
  Future<void> likePhoto(String photoId) async {
    liked.add(photoId);
    final gate = likeGate;
    if (likeError != null) throw likeError!;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> unlikePhoto(String photoId) async {
    unliked.add(photoId);
  }

  @override
  Future<Map<String, dynamic>?> getMyQrToken(String eventId) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> validateQrToken(
    String eventId,
    String token,
  ) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> createEvent(Map<String, dynamic> data) =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> listEvents([String? status, String? type]) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> getEvent(String id) =>
      throw UnimplementedError();

  @override
  Future<Event?> getEventByInviteToken(String token) =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> getEventPromotores(String eventId) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>?> getMyEventInvite(String eventId) =>
      throw UnimplementedError();

  @override
  Future<void> updateEvent(String id, Map<String, dynamic> patch) =>
      throw UnimplementedError();
}

class _FakeModerationService implements ModerationService {
  final List<(String, String, String)> reports = [];

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  GoTrueClient get auth => throw UnimplementedError();

  @override
  Future<void> reportContent(
    String targetType,
    String targetId,
    String reason,
  ) async {
    reports.add((targetType, targetId, reason));
  }
}

/// Screen-level upload seam for the widget tests: the real
/// [PhotoUploadNotifier] runs [ImageProcessor.compressBytes], whose dart:ui
/// codec futures never complete under `testWidgets`' fake-async zone — the
/// repo's other upload screens (create_event, create_group, avatar) hit the
/// same wall and fake the upload layer in widget tests instead. The real
/// pick→compress→upload pipeline stays covered by the provider-level tests
/// above, which run in the real async zone.
class _FakeUploadNotifier extends PhotoUploadNotifier {
  @override
  Future<void> upload(String eventId, XFile file) async {
    state = const AsyncData(PhotoUploadState.uploading());
    try {
      final bytes = await file.readAsBytes();
      await ref
          .read(mediaServiceProvider)
          .uploadEventPhotoBytes(eventId, bytes);
      state = const AsyncData(PhotoUploadState.uploaded());
      ref.invalidate(eventPhotosProvider(eventId));
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }
}

class _FakeEventDetailNotifier extends EventDetailNotifier {
  _FakeEventDetailNotifier(this.endsAt);

  final DateTime? endsAt;

  @override
  Future<Map<String, dynamic>> build(String arg) async => _event(
        endsAt: endsAt,
      );
}

ProviderContainer _container({
  _FakeMediaService? media,
  _FakeEventService? events,
  _FakeModerationService? moderation,
  Map<String, String> config = const {},
  DateTime? endsAt,
  bool fakeUpload = false,
}) {
  final container = ProviderContainer(overrides: [
    mediaServiceProvider.overrideWithValue(media ?? _FakeMediaService()),
    eventServiceProvider.overrideWithValue(events ?? _FakeEventService()),
    moderationServiceProvider
        .overrideWithValue(moderation ?? _FakeModerationService()),
    appConfigProvider.overrideWith(() => FakeAppConfigNotifier(config)),
    eventDetailProvider
        .overrideWith(() => _FakeEventDetailNotifier(endsAt)),
    if (fakeUpload)
      uploadPhotoProvider.overrideWith(() => _FakeUploadNotifier()),
  ]);
  addTearDown(container.dispose);
  return container;
}

Future<ProviderContainer> _pumpGallery(
  WidgetTester tester, {
  _FakeMediaService? media,
  _FakeEventService? events,
  _FakeModerationService? moderation,
  Map<String, String> config = const {},
  DateTime? endsAt,
  PermissionService? permissions,
  PhotoPicker? picker,
  bool fakeUpload = false,
}) async {
  final container = _container(
    media: media,
    events: events,
    moderation: moderation,
    config: config,
    endsAt: endsAt,
    fakeUpload: fakeUpload,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PhotoGalleryScreen(
          eventId: _eventId,
          permissions: permissions,
          picker: picker,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('EventPhotosNotifier', () {
    test('build maps rows to photos with signed URLs and likedByMe', () async {
      final media = _FakeMediaService(rows: [
        _photoRow('p-1'),
        _photoRow('p-2', storagePath: 'e-1/photos/b.png', likes: 4),
      ]);
      final events = _FakeEventService(myLikes: ['p-2']);
      final container = _container(media: media, events: events);

      final photos = await container.read(eventPhotosProvider(_eventId).future);

      expect(photos, hasLength(2));
      expect(photos[0].id, 'p-1');
      expect(photos[0].signedUrl, 'signed://e-1/photos/x.png');
      expect(photos[0].likedByMe, isFalse);
      expect(photos[1].signedUrl, 'signed://e-1/photos/b.png');
      expect(photos[1].likedByMe, isTrue);
      expect(photos[1].likesCount, 4);
    });

    test('caches signed URLs across refreshes (one call per photo)', () async {
      final media = _FakeMediaService(rows: [
        _photoRow('p-1'),
        _photoRow('p-2'),
      ]);
      final container = _container(media: media);
      await container.read(eventPhotosProvider(_eventId).future);
      final callsAfterFirstBuild = media.signedUrlCalls;

      await container.read(eventPhotosProvider(_eventId).notifier).refresh();
      await container.read(eventPhotosProvider(_eventId).future);

      expect(callsAfterFirstBuild, 2);
      expect(media.signedUrlCalls, 2,
          reason: 'a refresh must reuse the cached signed URLs');
    });

    test('refreshSignedUrl re-issues only the requested photo URL', () async {
      final media = _FakeMediaService(rows: [
        _photoRow('p-1'),
        _photoRow('p-2'),
      ]);
      final container = _container(media: media);
      await container.read(eventPhotosProvider(_eventId).future);

      await container
          .read(eventPhotosProvider(_eventId).notifier)
          .refreshSignedUrl('p-1');

      expect(media.signedUrlCalls, 3);
      final photos = container.read(eventPhotosProvider(_eventId)).valueOrNull!;
      expect(photos[0].signedUrl, 'signed://e-1/photos/x.png');
      expect(photos[1].signedUrl, 'signed://e-1/photos/x.png');
    });

    test('toggleLike is optimistic (state flips before the service resolves)',
        () async {
      final media = _FakeMediaService(rows: [_photoRow('p-1')]);
      final events = _FakeEventService();
      events.likeGate = Completer<void>();
      final container = _container(media: media, events: events);
      await container.read(eventPhotosProvider(_eventId).future);

      final notifier = container.read(eventPhotosProvider(_eventId).notifier);
      final pending = notifier.toggleLike('p-1');

      final midFlight =
          container.read(eventPhotosProvider(_eventId)).valueOrNull!;
      expect(midFlight.single.likedByMe, isTrue);
      expect(midFlight.single.likesCount, 1);

      events.likeGate!.complete();
      await pending;
      expect(events.liked, ['p-1']);
    });

    test('toggleLike rolls back when the service fails', () async {
      final media = _FakeMediaService(rows: [_photoRow('p-1', likes: 5)]);
      final events = _FakeEventService()
        ..likeError = Exception('boom');
      final container = _container(media: media, events: events);
      await container.read(eventPhotosProvider(_eventId).future);

      final notifier = container.read(eventPhotosProvider(_eventId).notifier);
      await expectLater(notifier.toggleLike('p-1'), throwsException);

      final photos = container.read(eventPhotosProvider(_eventId)).valueOrNull!;
      expect(photos.single.likedByMe, isFalse);
      expect(photos.single.likesCount, 5,
          reason: 'rollback restores the pre-tap count');
    });

    test('toggleLike unlikes an already-liked photo', () async {
      final media = _FakeMediaService(rows: [_photoRow('p-1', likes: 3)]);
      final events = _FakeEventService(myLikes: ['p-1']);
      final container = _container(media: media, events: events);
      await container.read(eventPhotosProvider(_eventId).future);

      await container
          .read(eventPhotosProvider(_eventId).notifier)
          .toggleLike('p-1');

      expect(events.unliked, ['p-1']);
      final photos = container.read(eventPhotosProvider(_eventId)).valueOrNull!;
      expect(photos.single.likedByMe, isFalse);
      expect(photos.single.likesCount, 2);
    });

    test('report delegates to the moderation service with a photo target',
        () async {
      final media = _FakeMediaService(rows: [_photoRow('p-1')]);
      final moderation = _FakeModerationService();
      final container =
          _container(media: media, moderation: moderation);
      await container.read(eventPhotosProvider(_eventId).future);

      await container
          .read(eventPhotosProvider(_eventId).notifier)
          .report('p-1', 'Contenido inapropiado');

      expect(moderation.reports, [('photo', 'p-1', 'Contenido inapropiado')]);
    });

    test('surfaces AsyncError when listing fails', () async {
      final media = _FakeMediaService()..listError = Exception('boom');
      final container = _container(media: media);

      await expectLater(
        container.read(eventPhotosProvider(_eventId).future),
        throwsException,
      );
      expect(
        container.read(eventPhotosProvider(_eventId)),
        isA<AsyncError>(),
      );
    });
  });

  group('SignedUrlCache', () {
    test('serves the cached URL while valid and re-fetches after expiry',
        () async {
      var now = DateTime(2026, 8, 9, 12);
      final cache = SignedUrlCache(clock: () => now);
      var fetches = 0;
      Future<String> fetch() async {
        fetches++;
        return 'url-$fetches';
      }

      expect(await cache.urlFor('p-1', fetch), 'url-1');
      expect(await cache.urlFor('p-1', fetch), 'url-1',
          reason: 'within TTL the fetch must not run again');
      expect(fetches, 1);

      now = now.add(const Duration(hours: 1, minutes: 10));
      expect(await cache.urlFor('p-1', fetch), 'url-2');
      expect(fetches, 2);
    });

    test('re-fetches during the grace window before the hard expiry', () async {
      var now = DateTime(2026, 8, 9, 12);
      final cache = SignedUrlCache(clock: () => now);
      var fetches = 0;
      Future<String> fetch() async {
        fetches++;
        return 'url-$fetches';
      }

      await cache.urlFor('p-1', fetch);
      now = now.add(const Duration(hours: 1) - const Duration(minutes: 1));
      await cache.urlFor('p-1', fetch);
      expect(fetches, 2,
          reason: 'a URL within grace of expiry is replaced pre-emptively');
    });

    test('invalidate forces the next fetch (401 self-heal)', () async {
      final cache = SignedUrlCache(clock: () => DateTime(2026, 8, 9, 12));
      var fetches = 0;
      Future<String> fetch() async {
        fetches++;
        return 'url-$fetches';
      }

      await cache.urlFor('p-1', fetch);
      cache.invalidate('p-1');
      await cache.urlFor('p-1', fetch);
      expect(fetches, 2);
    });
  });

  group('upload window helpers', () {
    test('photoUploadWindowHours reads the config with a default fallback',
        () {
      expect(
        photoUploadWindowHours({
          photoUploadWindowHoursKey: '48',
        }),
        48,
      );
      expect(photoUploadWindowHours(const {}), 24);
      expect(photoUploadWindowHours({photoUploadWindowHoursKey: 'nope'}), 24);
    });

    test('isPhotoUploadWindowOpen covers live + post-event window', () {
      final endsAt = DateTime(2026, 8, 9, 20);

      expect(
        isPhotoUploadWindowOpen(DateTime(2026, 8, 9, 19), endsAt, 24),
        isTrue,
        reason: 'during the event',
      );
      expect(
        isPhotoUploadWindowOpen(DateTime(2026, 8, 9, 21), endsAt, 24),
        isTrue,
        reason: 'within the post-event window',
      );
      expect(
        isPhotoUploadWindowOpen(DateTime(2026, 8, 11, 21, 1), endsAt, 24),
        isFalse,
        reason: 'past the window',
      );
      expect(
        isPhotoUploadWindowOpen(DateTime(2026, 8, 9, 21), null, 24),
        isFalse,
        reason: 'unknown event end is fail-closed',
      );
    });
  });

  group('PhotoUploadNotifier', () {
    test('uploads compressed bytes and invalidates the gallery', () async {
      final media = _FakeMediaService(rows: [_photoRow('p-1')]);
      final container = _container(media: media);
      await container.read(eventPhotosProvider(_eventId).future);
      final listCallsAfterFirstBuild = media.listCalls;

      final png = await _tinyPng();
      await container
          .read(uploadPhotoProvider.notifier)
          .upload(_eventId, XFile.fromData(png, name: 'foto.png'));

      expect(media.uploadedEventId, _eventId);
      expect(media.uploaded, hasLength(1));
      expect(media.uploaded.single, png,
          reason: 'small payloads pass compression unchanged');
      expect(
        container.read(uploadPhotoProvider).valueOrNull?.status,
        PhotoUploadStatus.uploaded,
      );

      media.rows = [...media.rows, _photoRow('p-2')];
      final photos = await container.read(eventPhotosProvider(_eventId).future);
      expect(photos, hasLength(2),
          reason: 'invalidate() forces the gallery to reload after upload');
      expect(media.listCalls, listCallsAfterFirstBuild + 1);
      expect(media.signedUrlCalls, 2,
          reason: 'the reload reuses the cached p-1 URL and only re-issues p-2');
    });

    test('surfaces the error state and rethrows on failure', () async {
      final media = _FakeMediaService();
      media.uploadError = Exception('boom');
      final container = _container(media: media);

      // A header-valid payload (tiny PNG) so the failure is the upload
      // itself, not the ImageProcessor header validation.
      final png = await _tinyPng();
      await expectLater(
        container
            .read(uploadPhotoProvider.notifier)
            .upload(_eventId, XFile.fromData(png, name: 'foto.png')),
        throwsException,
      );
      expect(container.read(uploadPhotoProvider), isA<AsyncError>());
    });
  });

  group('PhotoGalleryScreen', () {
    testWidgets('renders the photo grid with signed-URL tiles and like counts',
        (tester) async {
      final media = _FakeMediaService(rows: [
        _photoRow('p-1', storagePath: 'e-1/photos/a.png', likes: 0),
        _photoRow('p-2', storagePath: 'e-1/photos/b.png', likes: 3),
      ]);
      await _pumpGallery(tester, media: media);

      expect(find.byType(PhotoGalleryScreen), findsOneWidget);
      expect(find.text('Fotos'), findsOneWidget);
      expect(find.byType(VNetworkImage), findsNWidgets(2));
      expect(find.text('0 likes'), findsOneWidget);
      expect(find.text('3 likes'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border), findsNWidgets(2));
    });

    testWidgets('shows the empty state', (tester) async {
      await _pumpGallery(tester);

      expect(find.text('No hay fotos todavía'), findsOneWidget);
      expect(find.text('¡Sé el primero en subir una!'), findsOneWidget);
      expect(find.byType(VEmptyView), findsOneWidget);
    });

    testWidgets('shows the error view and recovers via retry', (tester) async {
      final media = _FakeMediaService()..listError = Exception('boom');
      await _pumpGallery(tester, media: media);

      expect(find.byType(ErrorView), findsOneWidget);

      media.listError = null;
      await tester.tap(find.text('Reintentar'));
      await tester.pumpAndSettle();

      expect(find.byType(ErrorView), findsNothing);
      expect(find.text('No hay fotos todavía'), findsOneWidget);
    });

    testWidgets('a like tap flips the heart and calls the service',
        (tester) async {
      final media = _FakeMediaService(rows: [_photoRow('p-1')]);
      final events = _FakeEventService();
      await _pumpGallery(tester, media: media, events: events);

      await tester.tap(find.byKey(const ValueKey('photo-like-p-1')));
      await tester.pumpAndSettle();

      expect(events.liked, ['p-1']);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.text('1 likes'), findsOneWidget);
    });

    testWidgets('long-press opens the report dialog and submits',
        (tester) async {
      final media = _FakeMediaService(rows: [_photoRow('p-1')]);
      final moderation = _FakeModerationService();
      await _pumpGallery(tester, media: media, moderation: moderation);

      await tester.longPress(find.byKey(const ValueKey('photo-tile-p-1')));
      await tester.pumpAndSettle();

      expect(find.text('Reportar foto'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Contenido inapropiado');
      await tester.tap(find.text('Enviar reporte'));
      await tester.pumpAndSettle();

      expect(moderation.reports, [('photo', 'p-1', 'Contenido inapropiado')]);
      expect(find.text('Reporte enviado'), findsOneWidget);
    });

    testWidgets('the upload flow picks, compresses and uploads', (tester) async {
      final media = _FakeMediaService(rows: [_photoRow('p-1')]);
      // dart:ui image futures never complete under the fake-async widget-test
      // zone — generate the PNG in the real zone first (repo pattern, see
      // create_event_test.dart `_solidPng`).
      final png = (await tester.runAsync(_tinyPng))!;
      final permissions = PermissionService(
        request: (_) async => ph.PermissionStatus.granted,
      );
      Future<XFile?> picker(ImageSource source) async =>
          XFile.fromData(png, name: 'foto.png');
      await _pumpGallery(
        tester,
        media: media,
        permissions: permissions,
        picker: picker,
        fakeUpload: true,
      );

      await tester.tap(find.byKey(const ValueKey('photos-upload-button')));
      await tester.pumpAndSettle();

      expect(media.uploadedEventId, _eventId);
      expect(media.uploaded, hasLength(1));
      expect(media.uploaded.single, png);
      expect(find.text('Foto subida'), findsOneWidget);
    });

    testWidgets('a denied photo permission aborts the upload', (tester) async {
      final media = _FakeMediaService(rows: [_photoRow('p-1')]);
      final png = (await tester.runAsync(_tinyPng))!;
      final permissions = PermissionService(
        request: (_) async => ph.PermissionStatus.denied,
      );
      Future<XFile?> picker(ImageSource source) async =>
          XFile.fromData(png, name: 'foto.png');
      await _pumpGallery(
        tester,
        media: media,
        permissions: permissions,
        picker: picker,
      );

      await tester.tap(find.byKey(const ValueKey('photos-upload-button')));
      await tester.pumpAndSettle();

      expect(media.uploaded, isEmpty);
      expect(find.byType(SnackBar), findsOneWidget,
          reason: 'denied permission shows the rationale snackbar');
    });

    testWidgets('a closed upload window hides the button and shows the notice',
        (tester) async {
      final media = _FakeMediaService(rows: [_photoRow('p-1')]);
      await _pumpGallery(
        tester,
        media: media,
        endsAt: DateTime(2020, 1, 1),
      );

      expect(
        find.text('La ventana de subida de fotos ya cerró'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('photos-upload-button')),
        findsNothing,
      );
      expect(find.byType(VNetworkImage), findsOneWidget,
          reason: 'the gallery stays readable after the window closes');
    });

    testWidgets('the empty state offers the upload CTA while the window is '
        'open', (tester) async {
      await _pumpGallery(tester);

      expect(find.text('Subir foto'), findsOneWidget);
    });
  });
}

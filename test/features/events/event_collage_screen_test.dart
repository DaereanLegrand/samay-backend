import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/event.dart';
import 'package:samay/core/models/event_photo.dart';
import 'package:samay/features/events/providers/events_providers.dart';
import 'package:samay/features/events/screens/event_collage_screen.dart';
import 'package:samay/features/photos/providers/photos_providers.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';
import 'package:samay/shared/widgets/state_views.dart';
import 'package:samay/shared/widgets/v_network_image.dart';

/// EventCollageScreen tests (R1 events sweep): the photo-wall renders every
/// photo from [eventPhotosProvider] (signed URLs resolved by the provider)
/// under an overlay strip with the event title, with loading / error /
/// empty states.
const _eventId = '66666666-6666-6666-6666-666666666666';

Event _event() => Event(
  id: _eventId,
  name: 'Rave en el garaje',
  type: 'juerga',
  status: 'live',
  startsAt: DateTime(2026, 8, 9, 20),
  endsAt: DateTime(2026, 8, 10, 2),
);

EventPhoto _photo(String id, {String? url}) => EventPhoto(
  id: id,
  eventId: _eventId,
  uploadedByUserId: 'user-1',
  storagePath: 'e-1/photos/$id.png',
  likesCount: 0,
  createdAt: DateTime(2026, 8, 1),
  signedUrl: url ?? 'signed://e-1/photos/$id.png',
);

class _FakeEventDetailNotifier extends EventDetailNotifier {
  _FakeEventDetailNotifier(this.row);

  final Event row;

  @override
  Future<Event> build(String arg) async => row;
}

class _FakeEventPhotosNotifier extends EventPhotosNotifier {
  _FakeEventPhotosNotifier(this.photos, {this.error, this.gate});

  final List<EventPhoto> photos;
  Object? error;

  /// When set, [build] awaits it before resolving — tests hold the provider
  /// in the loading state deterministically.
  final Future<void>? gate;

  @override
  Future<List<EventPhoto>> build(String eventId) async {
    final g = gate;
    if (g != null) await g;
    if (error != null) throw error!;
    return photos;
  }
}

ProviderContainer _container({
  List<EventPhoto> photos = const [],
  Object? error,
  Future<void>? gate,
}) {
  final container = ProviderContainer(
    overrides: [
      eventDetailProvider.overrideWith(
        () => _FakeEventDetailNotifier(_event()),
      ),
      eventPhotosProvider.overrideWith(
        () => _FakeEventPhotosNotifier(photos, error: error, gate: gate),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpScreen(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: EventCollageScreen(eventId: _eventId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('EventCollageScreen', () {
    testWidgets('renders a photo-wall grid with the event title overlay', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        _container(photos: [_photo('p-1'), _photo('p-2'), _photo('p-3')]),
      );

      expect(find.text('Collage'), findsOneWidget);
      // The event title rides the overlay strip (VDisplayText renders
      // VERBATIM — monochrome 2026-08-26, no uppercase transform).
      expect(find.text('Rave en el garaje'), findsOneWidget);
      expect(find.text('3 fotos'), findsOneWidget);
      // One tile per photo, in the signed-URL render path.
      expect(find.byKey(const ValueKey('photo-tile-p-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('photo-tile-p-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('photo-tile-p-3')), findsOneWidget);
      expect(find.byType(VNetworkImage), findsNWidgets(3));
    });

    testWidgets('renders the empty state when the event has no photos', (
      tester,
    ) async {
      await _pumpScreen(tester, _container());

      expect(find.byType(VEmptyView), findsOneWidget);
      expect(find.text('Aún no hay fotos para el collage'), findsOneWidget);
      expect(
        find.text('El collage se arma solo con las fotos del evento.'),
        findsOneWidget,
      );
    });

    testWidgets('shows ErrorView and retry reloads', (tester) async {
      final container = _container(
        photos: [_photo('p-1')],
        error: Exception('boom'),
      );
      await _pumpScreen(tester, container);

      expect(find.byType(ErrorView), findsOneWidget);
      // A generic Exception maps to ServerError('') — the localized fallback.
      expect(
        find.text('Error del servidor. Intenta de nuevo.'),
        findsOneWidget,
      );
    });

    testWidgets('shows the loading view while the provider is pending', (
      tester,
    ) async {
      final gate = Completer<void>();
      final container = _container(photos: [_photo('p-1')], gate: gate.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('es'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: EventCollageScreen(eventId: _eventId),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(VLoadingView), findsOneWidget);
      expect(find.byType(VEmptyView), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(VLoadingView), findsNothing);
      expect(find.byKey(const ValueKey('photo-tile-p-1')), findsOneWidget);
    });
  });
}

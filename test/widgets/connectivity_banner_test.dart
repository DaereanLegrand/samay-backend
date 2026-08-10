import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/services/connectivity_service.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/connectivity_banner.dart';

const _esOffline = 'Sin conexión — los datos podrían no estar actualizados';
const _enOffline = 'No connection — data might not be up to date';

Widget _wrap(Stream<bool> stream, {Locale? locale}) {
  return ProviderScope(
    overrides: [
      connectivityServiceProvider.overrideWithValue(
        ConnectivityService(onConnectivityChanged: () => stream),
      ),
    ],
    child: MaterialApp(
      locale: locale ?? const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: const ConnectivityBanner()),
    ),
  );
}

/// I-67: the global offline banner is optimistic (hidden while the status is
/// loading or unknown), shows the localized copy only while the device is
/// offline, and disappears as soon as connectivity returns.
void main() {
  group('ConnectivityBanner', () {
    testWidgets('is hidden while online', (tester) async {
      await tester.pumpWidget(_wrap(Stream.value(true)));
      await tester.pumpAndSettle();

      expect(find.text(_esOffline), findsNothing);
      expect(find.byIcon(Icons.wifi_off), findsNothing);
    });

    testWidgets('shows the localized offline copy (es)', (tester) async {
      await tester.pumpWidget(_wrap(Stream.value(false)));
      await tester.pumpAndSettle();

      expect(find.text(_esOffline), findsOneWidget);
      expect(find.byIcon(Icons.wifi_off), findsOneWidget);
    });

    testWidgets('shows the localized offline copy (en)', (tester) async {
      await tester.pumpWidget(
        _wrap(Stream.value(false), locale: const Locale('en')),
      );
      await tester.pumpAndSettle();

      expect(find.text(_enOffline), findsOneWidget);
    });

    testWidgets('appears when connectivity drops and disappears on recovery',
        (tester) async {
      final controller = StreamController<bool>();
      addTearDown(controller.close);
      await tester.pumpWidget(_wrap(controller.stream));

      controller.add(true);
      await tester.pumpAndSettle();
      expect(find.text(_esOffline), findsNothing);

      controller.add(false);
      await tester.pumpAndSettle();
      expect(find.text(_esOffline), findsOneWidget);

      controller.add(true);
      await tester.pumpAndSettle();
      expect(find.text(_esOffline), findsNothing);
    });

    testWidgets('stays hidden while the first status is still loading '
        '(optimistic initial)', (tester) async {
      await tester.pumpWidget(_wrap(Stream<bool>.multi((_) {})));
      await tester.pumpAndSettle();

      expect(find.text(_esOffline), findsNothing);
      expect(find.byIcon(Icons.wifi_off), findsNothing);
    });

    testWidgets('stays hidden when the status stream errors (fail-open)',
        (tester) async {
      final controller = StreamController<bool>();
      addTearDown(controller.close);
      await tester.pumpWidget(_wrap(controller.stream));

      controller.addError(Exception('plugin unavailable'));
      await tester.pumpAndSettle();

      expect(find.text(_esOffline), findsNothing);
      expect(find.byIcon(Icons.wifi_off), findsNothing);
    });
  });
}

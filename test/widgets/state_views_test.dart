import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_icon_sizes.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';
import 'package:samay/shared/widgets/state_views.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  group('VLoadingView', () {
    testWidgets('renders a centered spinner', (tester) async {
      await tester.pumpWidget(_wrap(const VLoadingView()));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('renders the optional label below the spinner', (tester) async {
      await tester.pumpWidget(_wrap(const VLoadingView(label: 'Cargando…')));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Cargando…'), findsOneWidget);
    });

    testWidgets('hides the label when not provided', (tester) async {
      await tester.pumpWidget(_wrap(const VLoadingView()));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('spinner is white per DESIGN.md §5.8', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const VLoadingView()));
      final spinner = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(spinner.color, AppColors.white);
    });

    testWidgets('is const-constructible', (tester) async {
      const view = VLoadingView(label: 'Cargando…');
      expect(view, isA<VLoadingView>());
    });
  });

  group('VEmptyView', () {
    testWidgets('renders the default inbox icon and the title', (tester) async {
      await tester.pumpWidget(_wrap(const VEmptyView(title: 'Sin amigos')));
      expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
      expect(find.text('Sin amigos'), findsOneWidget);
    });

    testWidgets('renders a custom icon and an optional description', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const VEmptyView(
            icon: Icons.block,
            title: 'No has bloqueado a nadie',
            description: 'Los usuarios bloqueados aparecen aquí.',
          ),
        ),
      );
      expect(find.byIcon(Icons.block), findsOneWidget);
      expect(find.byIcon(Icons.inbox_outlined), findsNothing);
      expect(find.text('No has bloqueado a nadie'), findsOneWidget);
      expect(
        find.text('Los usuarios bloqueados aparecen aquí.'),
        findsOneWidget,
      );
    });

    testWidgets('hides the description when not provided', (tester) async {
      await tester.pumpWidget(_wrap(const VEmptyView(title: 'Vacío')));
      expect(find.byType(Text), findsOneWidget);
    });

    testWidgets('renders the action button and fires onAction', (tester) async {
      var acted = false;
      await tester.pumpWidget(
        _wrap(
          VEmptyView(
            title: 'Sin solicitudes',
            actionLabel: 'Agregar amigos',
            onAction: () => acted = true,
          ),
        ),
      );
      expect(find.text('Agregar amigos'), findsOneWidget);

      await tester.tap(find.text('Agregar amigos'));
      expect(acted, isTrue);
    });

    testWidgets('defaults the action label to commonContinue', (tester) async {
      await tester.pumpWidget(
        _wrap(VEmptyView(title: 'Vacío', onAction: () {})),
      );
      expect(find.text('Continuar'), findsOneWidget);
    });

    testWidgets('hides the action button when onAction is null', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const VEmptyView(title: 'Vacío')));
      expect(find.text('Continuar'), findsNothing);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('uses border grey for the icon and mutedStrong bodyMedium for '
        'the copy (§5.9)', (tester) async {
      await tester.pumpWidget(
        _wrap(const VEmptyView(title: 'Vacío', description: 'Descripción')),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.inbox_outlined));
      expect(icon.color, AppColors.border);
      expect(icon.size, AppIconSizes.xxl);
      final description = tester.widget<Text>(find.text('Descripción'));
      expect(description.style?.color, AppColors.mutedStrong);
      expect(description.style?.fontSize, 14);
    });

    testWidgets('is const-constructible', (tester) async {
      const view = VEmptyView(title: 'Vacío');
      expect(view, isA<VEmptyView>());
    });
  });

  group('VStateView', () {
    testWidgets('loading branch wins over an error', (tester) async {
      await tester.pumpWidget(
        _wrap(VStateView(loading: true, error: Exception('boom'))),
      );
      expect(find.byType(VLoadingView), findsOneWidget);
      expect(find.byType(ErrorView), findsNothing);
    });

    testWidgets('error branch shows ErrorView with the mapped message', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          VStateView(
            loading: false,
            error: Exception('boom'),
            errorMessage: 'No se pudo cargar',
          ),
        ),
      );
      expect(find.byType(VLoadingView), findsNothing);
      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('No se pudo cargar'), findsOneWidget);
    });

    testWidgets('error branch falls back to error.toString()', (tester) async {
      await tester.pumpWidget(_wrap(VStateView(error: Exception('boom'))));
      expect(find.textContaining('Exception'), findsOneWidget);
    });

    testWidgets('error retry fires onRetry', (tester) async {
      var retried = false;
      await tester.pumpWidget(
        _wrap(
          VStateView(
            error: Exception('boom'),
            errorMessage: 'Fallo',
            onRetry: () => retried = true,
          ),
        ),
      );
      await tester.tap(find.text('Reintentar'));
      expect(retried, isTrue);
    });

    testWidgets('data branch renders the child', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VStateView(
            empty: VEmptyView(title: 'Vacío'),
            child: Text('DATA'),
          ),
        ),
      );
      expect(find.text('DATA'), findsOneWidget);
      expect(find.text('Vacío'), findsNothing);
    });

    testWidgets('child wins over empty when both are provided', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VStateView(
            empty: VEmptyView(title: 'Vacío'),
            child: Text('DATA'),
          ),
        ),
      );
      expect(find.text('DATA'), findsOneWidget);
      expect(find.text('Vacío'), findsNothing);
    });

    testWidgets('empty branch renders the empty view when child is null', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const VStateView(empty: VEmptyView(title: 'Vacío'))),
      );
      expect(find.byType(VEmptyView), findsOneWidget);
      expect(find.text('Vacío'), findsOneWidget);
    });

    testWidgets('renders nothing when every branch is idle', (tester) async {
      await tester.pumpWidget(_wrap(const VStateView()));
      expect(find.byType(VLoadingView), findsNothing);
      expect(find.byType(ErrorView), findsNothing);
      expect(find.byType(VEmptyView), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('is const-constructible', (tester) async {
      const view = VStateView(loading: true);
      expect(view, isA<VStateView>());
    });
  });
}

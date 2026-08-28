import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/shared/widgets/v_display_text.dart';
import 'package:samay/shared/widgets/v_header_bar.dart';

void main() {
  group('VHeaderBar', () {
    testWidgets('renders the title in the Playfair display voice, white',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: VHeaderBar(title: 'Mis eventos')),
        ),
      );
      expect(find.text('Mis eventos'), findsOneWidget);
      final display = tester.widget<VDisplayText>(
        find.byType(VDisplayText),
      );
      expect(display.text, 'Mis eventos');
      expect(display.size, 40, reason: 'matches the Mis Eventos header hero');
    });

    testWidgets('shows a back arrow that pops when a route can pop',
        (tester) async {
      var popped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: VHeaderBar(
                title: 'Título',
                onBack: () => popped = true,
              ),
            ),
          ),
        ),
      );
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      expect(popped, isTrue);
    });

    testWidgets('hides the back arrow when showBack is false (tab screens)',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: VHeaderBar(title: 'Feed', showBack: false),
          ),
        ),
      );
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('renders a bare back arrow when no title is given',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: VHeaderBar()),
        ),
      );
      expect(find.byType(VDisplayText), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
    });

    testWidgets('passes actions through in the trailing slot', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: VHeaderBar(
              title: 'Ajustes',
              actions: [Icon(Icons.settings)],
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.settings), findsOneWidget);
    });

    testWidgets('expands child content below the header when given',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: VHeaderBar(
              title: 'Feed',
              showBack: false,
              child: Center(child: Text('contenido')),
            ),
          ),
        ),
      );
      expect(find.text('contenido'), findsOneWidget);
      expect(find.text('Feed'), findsOneWidget);
    });

    testWidgets('ellipsizes long titles with maxLines 1', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: VHeaderBar(
              title: 'Un título tan largo que no cabe en una sola línea',
            ),
          ),
        ),
      );
      final display = tester.widget<VDisplayText>(
        find.byType(VDisplayText),
      );
      expect(display.maxLines, 1);
    });
  });
}

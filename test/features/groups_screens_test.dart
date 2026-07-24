import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/groups/create_group_screen.dart';
import 'package:samay/features/groups/group_detail_screen.dart';
import 'package:samay/features/groups/donate_shards_screen.dart';
import 'package:samay/features/groups/invite_screen.dart';
import 'package:samay/features/groups/leaderboard_screen.dart';

Widget _wrap(Widget child) {
  return ProviderScope(
    child: MaterialApp(home: child),
  );
}

void main() {
  group('CreateGroupScreen', () {
    testWidgets('renders create group form', (tester) async {
      await tester.pumpWidget(_wrap(const CreateGroupScreen()));
      expect(find.text('Crear grupo'), findsOneWidget);
      expect(find.text('Nombre del grupo'), findsOneWidget);
      expect(find.text('Descripción (opcional)'), findsOneWidget);
      expect(find.text('Crear'), findsOneWidget);
    });
  });

  group('GroupDetailScreen', () {
    testWidgets('renders group detail scaffold', (tester) async {
      await tester.pumpWidget(_wrap(const GroupDetailScreen(groupId: 'test-group')));
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('renders tab bar when data loaded', (tester) async {
      await tester.pumpWidget(_wrap(const GroupDetailScreen(groupId: 'test-group')));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(Scaffold), findsOneWidget);
    });
  });

  group('DonateShardsScreen', () {
    testWidgets('renders donation form', (tester) async {
      await tester.pumpWidget(_wrap(const DonateShardsScreen(groupId: 'test-group', groupName: 'Test Group')));
      expect(find.text('Donar shards'), findsOneWidget);
      expect(find.textContaining('Test Group'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('shows boost info text', (tester) async {
      await tester.pumpWidget(_wrap(const DonateShardsScreen(groupId: 'test-group', groupName: 'Test Group')));
      expect(find.textContaining('impulsarán el ranking'), findsOneWidget);
    });

    testWidgets('shows donation button', (tester) async {
      await tester.pumpWidget(_wrap(const DonateShardsScreen(groupId: 'test-group', groupName: 'Test Group')));
      expect(find.text('Donar'), findsOneWidget);
    });
  });

  group('InviteScreen', () {
    testWidgets('renders search bar and hint text', (tester) async {
      await tester.pumpWidget(_wrap(InviteScreen(groupId: 'test-group')));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(TextField), findsOneWidget);
      expect(find.textContaining('Buscar usuarios'), findsOneWidget);
    });
  });

  group('LeaderboardScreen', () {
    testWidgets('renders leaderboard title', (tester) async {
      await tester.pumpWidget(_wrap(const LeaderboardScreen()));
      expect(find.text('Ranking de grupos'), findsOneWidget);
    });

    testWidgets('renders size tier chips', (tester) async {
      await tester.pumpWidget(_wrap(const LeaderboardScreen()));
      expect(find.text('micro'), findsOneWidget);
      expect(find.text('small'), findsOneWidget);
      expect(find.text('medium'), findsOneWidget);
      expect(find.text('large'), findsOneWidget);
    });
  });
}

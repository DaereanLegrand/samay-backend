import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vive_app/features/friends/search_screen.dart';
import 'package:vive_app/features/friends/requests_screen.dart';
import 'package:vive_app/features/friends/friends_list_screen.dart';
import 'package:vive_app/features/friends/blocked_users_screen.dart';

Widget _wrap(Widget child) {
  return ProviderScope(
    child: MaterialApp(home: child),
  );
}

void main() {
  group('SearchScreen', () {
    testWidgets('renders search bar and title', (tester) async {
      await tester.pumpWidget(_wrap(const SearchScreen()));
      expect(find.text('Buscar usuarios'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });
  });

  group('RequestsScreen', () {
    testWidgets('renders received and sent tabs', (tester) async {
      await tester.pumpWidget(_wrap(const RequestsScreen()));
      expect(find.text('Recibidas'), findsOneWidget);
      expect(find.text('Enviadas'), findsOneWidget);
    });
  });

  group('FriendsListScreen', () {
    testWidgets('renders friends list title', (tester) async {
      await tester.pumpWidget(_wrap(const FriendsListScreen()));
      expect(find.text('Amigos'), findsOneWidget);
    });

    testWidgets('renders search within friends', (tester) async {
      await tester.pumpWidget(_wrap(const FriendsListScreen()));
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('shows empty state when no friends', (tester) async {
      await tester.pumpWidget(_wrap(const FriendsListScreen()));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Sin amigos aún'), findsOneWidget);
      expect(find.text('Busca usuarios para agregar amigos'), findsOneWidget);
    });
  });

  group('BlockedUsersScreen', () {
    testWidgets('renders blocked users title', (tester) async {
      await tester.pumpWidget(_wrap(const BlockedUsersScreen()));
      expect(find.text('Usuarios bloqueados'), findsOneWidget);
    });

    testWidgets('shows empty state when no blocked users', (tester) async {
      await tester.pumpWidget(_wrap(const BlockedUsersScreen()));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('No has bloqueado a nadie'), findsOneWidget);
    });
  });
}

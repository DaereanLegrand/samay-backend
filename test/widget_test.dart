import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:samay/app.dart';

void main() {
  testWidgets('App renders MaterialApp', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: SamayApp()),
    );
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}

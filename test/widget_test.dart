import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:samay/app.dart';
import 'package:samay/core/services/connectivity_service.dart';

void main() {
  testWidgets('App renders MaterialApp', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // I-67: inert connectivity seam — the connectivity_plus plugin
          // cannot be listened to in the test environment (no platform
          // channel); the banner stays hidden on the optimistic loading state.
          connectivityServiceProvider.overrideWithValue(
            ConnectivityService(
              onConnectivityChanged: () => Stream<bool>.multi((_) {}),
            ),
          ),
        ],
        child: const SamayApp(),
      ),
    );
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}

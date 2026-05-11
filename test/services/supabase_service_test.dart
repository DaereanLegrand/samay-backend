import 'package:flutter_test/flutter_test.dart';
import 'package:vive_app/core/services/supabase_service.dart';

void main() {
  group('SupabaseService', () {
    test('can be instantiated', () {
      expect(SupabaseService.instance, isA<SupabaseService>());
    });

    test('has signIn method', () {
      expect(SupabaseService.instance.signIn, isA<Function>());
    });
  });
}

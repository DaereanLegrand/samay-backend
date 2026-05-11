import 'package:flutter_test/flutter_test.dart';
import 'package:vive_app/core/services/supabase_service.dart';

void main() {
  group('SupabaseService', () {
    test('can be instantiated', () {
      expect(SupabaseService, isA<Type>());
    });

    test('has signIn method', () {
      final service = SupabaseService();
      expect(service.signIn, isA<Function>());
    });
  });
}

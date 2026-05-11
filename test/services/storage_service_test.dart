import 'package:flutter_test/flutter_test.dart';
import 'package:vive_app/core/services/storage_service.dart';

void main() {
  group('StorageService', () {
    test('SecureStorageService is a class', () {
      expect(SecureStorageService, isA<Type>());
    });

    test('HiveService is a class', () {
      expect(HiveService, isA<Type>());
    });
  });
}

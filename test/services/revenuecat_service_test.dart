import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/extensions/error_mapper.dart';
import 'package:samay/core/services/revenuecat_service.dart';

/// RevenueCatService behavioral tests (I-61, PLAN/RSDK foundation):
/// stub mode (no `REVENUECAT_PUBLIC_SDK_KEY`) never touches the driver, and
/// the configured path delegates to the injectable [RevenueCatDriver] seam
/// (mocktail-mocked `purchases_flutter` wrapper).
class _MockRevenueCatDriver extends Mock implements RevenueCatDriver {}

void main() {
  group('stub mode (no REVENUECAT_PUBLIC_SDK_KEY)', () {
    test('isStubMode is true and isConfigured() resolves false', () async {
      final service = RevenueCatService();
      expect(service.isStubMode, isTrue);
      expect(await service.isConfigured(), isFalse);
    });

    test('currentInfo() returns null without touching the driver', () async {
      final service = RevenueCatService();
      expect(await service.currentInfo(), isNull);
    });

    test('purchase() throws the typed NotConfiguredError', () async {
      final service = RevenueCatService();
      await expectLater(
        service.purchase('pro_monthly'),
        throwsA(isA<NotConfiguredError>()),
      );
    });

    test('NotConfiguredError maps through the AppError pipeline', () async {
      final service = RevenueCatService();
      try {
        await service.purchase('pro_monthly');
        fail('expected NotConfiguredError');
      } on Object catch (e) {
        expect(e, isA<AppError>());
        expect(e.toAppError(), isA<NotConfiguredError>());
        expect((e as AppError).message, isNotEmpty);
      }
    });

    test('restorePurchases() completes without error (logged no-op)', () async {
      final service = RevenueCatService();
      await service.restorePurchases();
    });
  });

  group('configured mode (key present + injectable driver seam)', () {
    late _MockRevenueCatDriver driver;
    late RevenueCatService service;

    setUp(() {
      driver = _MockRevenueCatDriver();
      service = RevenueCatService(driver: driver, apiKey: 'rc_test_key');
    });

    test('isStubMode is false and isConfigured() delegates to the driver',
        () async {
      when(() => driver.isConfigured()).thenAnswer((_) async => true);
      expect(service.isStubMode, isFalse);
      expect(await service.isConfigured(), isTrue);
      verify(() => driver.isConfigured()).called(1);
    });

    test('currentInfo() surfaces the driver snapshot', () async {
      when(() => driver.currentInfo()).thenAnswer(
        (_) async =>
            const PurchaserInfo(activeEntitlements: {'pro', 'vip'}),
      );
      final info = await service.currentInfo();
      expect(info, isNotNull);
      expect(info!.activeEntitlements, {'pro', 'vip'});
      expect(info.hasActiveEntitlement, isTrue);
    });

    test('currentInfo() returns null when the driver has no info', () async {
      when(() => driver.currentInfo()).thenAnswer((_) async => null);
      expect(await service.currentInfo(), isNull);
    });

    test('purchase() forwards the product id to the driver', () async {
      when(() => driver.purchase('pro_monthly')).thenAnswer((_) async {});
      await service.purchase('pro_monthly');
      verify(() => driver.purchase('pro_monthly')).called(1);
    });

    test('restorePurchases() forwards to the driver', () async {
      when(() => driver.restore()).thenAnswer((_) async {});
      await service.restorePurchases();
      verify(() => driver.restore()).called(1);
    });

    test('driver failures propagate to the caller', () async {
      when(() => driver.purchase(any())).thenThrow(Exception('purchase failed'));
      await expectLater(
        service.purchase('pro_monthly'),
        throwsA(isA<Exception>()),
      );
    });
  });

  test('revenueCatServiceProvider resolves to a stub-mode service in tests',
      () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(revenueCatServiceProvider);
    expect(service, isA<RevenueCatService>());
    expect(service.isStubMode, isTrue);
  });
}

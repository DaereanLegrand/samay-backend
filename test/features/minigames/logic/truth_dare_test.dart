import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/minigames/logic/truth_dare.dart';
import 'package:samay/l10n/app_localizations.dart';

AppLocalizations _en() => lookupAppLocalizations(const Locale('en'));

void main() {
  group('TruthDareKind', () {
    test('wire values match the DB prompt_type strings', () {
      expect(TruthDareKind.truth.wire, 'verdad');
      expect(TruthDareKind.dare.wire, 'reto');
    });

    test('truthDareKindFromWire parses known values and null for others', () {
      expect(truthDareKindFromWire('verdad'), TruthDareKind.truth);
      expect(truthDareKindFromWire('reto'), TruthDareKind.dare);
      expect(truthDareKindFromWire(null), isNull);
      expect(truthDareKindFromWire('bogus'), isNull);
    });
  });

  group('truthDareKindLabel', () {
    test('maps to localized Verdad / Reto', () {
      expect(truthDareKindLabel(_en(), TruthDareKind.truth), 'Truth');
      expect(truthDareKindLabel(_en(), TruthDareKind.dare), 'Dare');
    });
  });

  group('truthDarePromptBody', () {
    test('reads the revealed prompt body from the prompt row', () {
      final body = truthDarePromptBody({
        'id': 'p-1',
        'body': '¿Cuál fue tu primer beso?',
      });
      expect(body, '¿Cuál fue tu primer beso?');
    });

    test('returns null when no prompt is revealed yet', () {
      expect(truthDarePromptBody(null), isNull);
      expect(truthDarePromptBody(const {}), isNull);
      expect(truthDarePromptBody({'body': ''}), isNull);
    });
  });

  group('truthDareChooseHeader', () {
    test('names the subject when known', () {
      final header = truthDareChooseHeader(_en(), 'María');
      expect(header, contains('María'));
      expect(header, contains('Truth or Dare'));
    });

    test('falls back to the generic line when the name is unknown', () {
      final header = truthDareChooseHeader(_en(), null);
      expect(header, 'Your turn! Pick Truth or Dare');
    });
  });
}

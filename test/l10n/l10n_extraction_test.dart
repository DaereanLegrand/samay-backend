import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Grep-based regression guard for the I-15 l10n mass extraction.
///
/// Scans the UI layer for hardcoded user-facing Spanish string literals:
/// `lib/features/**`, `lib/shared/widgets/**`, and
/// `lib/core/router/app_router.dart` must render every user-facing string
/// through `AppLocalizations.of(context)` — no raw Spanish literals in
/// widget-building contexts.
///
/// What the guard skips (documented, not user-facing):
///  * import statements and doc/comment lines (`///`, `//`)
///  * `AppLogger` calls (log messages, not UI text)
///  * `.select('...')` PostgREST column lists (DB query data)
///  * `${...}` interpolation segments, which may contain nested quotes
///  * pure data literals — map keys, statuses ('accepted', 'pending',
///    'blocked', 'received', 'sent'), DB role values ('member'), leaderboard
///    tier keys ('micro'..'large'), rank-bracket keys ('b90_100'..'b0_20')
///  * non-word UI glyphs — avatar fallback '?', rank prefix '#', username
///    handle prefix '@', role separator '·', size-tier letter 'U'
///  * numeric fallbacks — '0'/'14' (member-limit lookup in group detail)
///
/// `main_shell.dart` `TabItem.label` values are data keys; the rendered tab
/// text is localized in `MainShell.build` (`shell*` ARB keys) and
/// `main_shell_test.dart` asserts the es rendering still matches.
///
/// Error strings in `lib/core/errors/**` and service exceptions cannot reach
/// `BuildContext`, so they intentionally remain Spanish literals (mapped to
/// ARB at presentation time); they are out of scope for this guard.
const _scopeRoots = <String>[
  'lib/features',
  'lib/shared/widgets',
  'lib/core/router/app_router.dart',
];

const _dataAllowlist = <String>{
  '', // e.g. InputDecoration counterText, empty fallbacks
  '0', // group member-limit lookup fallback
  '14', // group member-limit lookup
  '@', // username handle prefix (interpolated: '@$username')
  '?', // avatar initial fallback
  'U', // public-profile avatar initial fallback
  '#', // leaderboard rank prefix
  '·', // role · separator in my-groups rows
  'member', // DB role value (groups members/invites)
  'accepted', // friendship_status value
  'pending', // friendship_status value
  'blocked', // friendship_status value
  'received', // friend-request direction value
  'sent', // friend-request direction value
  'invited', // group membership status value
  'micro', // leaderboard size-tier key
  'small', // leaderboard size-tier key
  'medium', // leaderboard size-tier key
  'large', // leaderboard size-tier key
  'b90_100', // rank-bracket key (renders localized label)
  'b80_90',
  'b60_80',
  'b40_60',
  'b20_40',
  'b0_20',
  'En la Búsqueda', // rank-bracket label (I-46 — BuildContext-free constant
  // in lib/shared/widgets/rank_bracket.dart, same rationale as error strings)
  'Creadores de la Vibra', // rank-bracket label (contains stopword 'creado')
  'La contraseña debe tener al menos 6 caracteres y contener un número.',
  // password-policy message (I-46 — BuildContext-free constant in
  // lib/features/auth/password_policy.dart, same rationale as error strings)
};

/// Common Spanish stopwords that no user-facing literal may contain once
/// extraction is complete. Covers accented and unaccented spellings.
const _spanishStopwords = <String>[
  'amigos', 'grupo', 'grupos', 'evento', 'eventos', 'miembros', 'miembro',
  'solicitud', 'solicitudes', 'solicitado', 'enviada', 'enviadas', 'enviado',
  'recibida', 'recibidas', 'invitaci', 'invitado', 'invitados', 'invitar',
  'invita', 'usuario', 'usuarios', 'perfil', 'configuracion', 'contrase',
  'correo', 'crea', 'crear', 'creado', 'guardar', 'guardado', 'donar',
  'donacion', 'shards', 'amistad', 'bloquea', 'desbloquear', 'rechazar',
  'aceptar', 'aceptando', 'cancelar', 'continuar', 'verificar', 'verifica',
  'fecha', 'nacimiento', 'años', 'debes', 'tener', 'menos', 'seleccionar',
  'ingresa', 'enviamos', 'codigo', 'registrad', 'terminos', 'condiciones',
  'politica', 'privacidad', 'servicio', 'completa', 'podras', 'cambiar',
  'volver', 'iniciar', 'sesion', 'olvide', 'cuenta', 'buscar', 'resultados',
  'notificaciones', 'proximamente', 'disponible', 'encontrad', 'portada',
  'nombre', 'descripcion', 'monto', 'exitosa', 'cantidad', 'congelado',
  'abandonar', 'seguro', 'contribuidores', 'ranking', 'caracteres', 'editar',
  'biografia', 'cambios', 'actualizado', 'compartidos', 'comun', 'reportar',
  'enviando', 'agregar', 'eliminar', 'deshacer', 'anonimizad', 'recuperar',
  'confirma', 'coincide', 'salio', 'intenta', 'solicitada', 'valida',
  'expiro', 'solicita', 'suficientes', 'existe', 'sucedio', 'pertenece',
  'ningun', 'unete', 'existente', 'impulsaran', 'dias', 'promotor',
  'transfiere', 'suscripci', 'bienvenido', 'fotos', 'collage', 'escaner',
  'suscripciones', 'mensajes', 'vinculados', 'datos', 'eliminada',
  'permanentemente', 'despues', 'accion', 'puede', 'mantendran', 'expira',
  'invitación', 'aplicación', 'realizar', 'restringida', 'salió', 'expiró',
  'amistad', 'código', 'ingrese', 'inténtalo', 'déjalo', 'mismos',
  'bienvenido', 'contraseñas', 'contraseña', 'correos', 'completo',
  'eliminado', 'recuperado', 'vinculados', 'recuperar', 'anonimizad',
  'deshacer', 'podrán', 'podrás', 'podras', 'encontrado', 'encontrada',
];

String _normalize(String s) => s
    .toLowerCase()
    .replaceAll('á', 'a')
    .replaceAll('é', 'e')
    .replaceAll('í', 'i')
    .replaceAll('ó', 'o')
    .replaceAll('ú', 'u')
    .replaceAll('ü', 'u')
    .replaceAll('ñ', 'n')
    .replaceAll('¿', '')
    .replaceAll('¡', '');

/// Removes `${...}` interpolation segments (balanced braces) so nested quotes
/// and interpolated data cannot pollute the literal scan.
String _stripInterpolations(String line) {
  var out = line;
  while (true) {
    final start = out.indexOf(r'${');
    if (start < 0) break;
    var depth = 1;
    var i = start + 2;
    while (i < out.length && depth > 0) {
      if (out[i] == '{') depth++;
      if (out[i] == '}') depth--;
      i++;
    }
    out = out.replaceRange(start, i, '');
  }
  return out;
}

Iterable<String> _literalsInLine(String line) sync* {
  final re = RegExp(r"'(?:[^'\\]|\\.)*'");
  for (final m in re.allMatches(line)) {
    final raw = m.group(0)!;
    yield raw.substring(1, raw.length - 1);
  }
}

bool _isLookupKey(String literal) => RegExp(r'^\w[\w.]*$').hasMatch(literal);

void main() {
  final files = <File>[];
  for (final root in _scopeRoots) {
    final entity = File(root);
    if (entity.existsSync()) {
      files.add(entity);
      continue;
    }
    final dir = Directory(root);
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      if (f.path.endsWith('.dart')) files.add(f);
    }
  }

  test('no hardcoded Spanish UI literal in the migrated scopes', () {
    final offenders = <String>[];
    for (final file in files) {
      for (final rawLine in file.readAsStringSync().split('\n')) {
        final line = rawLine.trimLeft();
        if (line.startsWith('import ') ||
            line.startsWith('///') ||
            line.startsWith('//') ||
            line.startsWith('*') ||
            line.contains('AppLogger.instance') ||
            line.contains('.select(')) {
          continue;
        }
        final stripped = _stripInterpolations(rawLine);
        for (final lit in _literalsInLine(stripped)) {
          if (_dataAllowlist.contains(lit)) continue;
          if (_isLookupKey(lit)) continue;
          final prose = _normalize(lit);
          final flagged = _spanishStopwords.any(prose.contains) ||
              prose.contains(RegExp('[áéíóúüñ¿¡]'));
          if (!flagged) continue;
          offenders.add('${file.path}: $lit');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'hardcoded user-facing literals remaining (I-15 extraction):\n'
          '${offenders.join('\n')}',
    );
  });

  test('shell tab labels render through AppLocalizations in MainShell', () {
    final shell = File('lib/core/router/main_shell.dart').readAsStringSync();
    expect(shell, contains('AppLocalizations.of(context)'));
    expect(shell, contains('shellFeed'));
    expect(shell, contains('shellProfile'));
  });
}

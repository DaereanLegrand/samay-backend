import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/minigames/logic/minigame_engine.dart';

void main() {
  group('minigamePhaseFromString', () {
    test('maps the wire phase values', () {
      expect(minigamePhaseFromString('playing'), MinigamePhase.playing);
      expect(minigamePhaseFromString('finished'), MinigamePhase.finished);
      expect(minigamePhaseFromString(null), MinigamePhase.setup);
      expect(minigamePhaseFromString('bogus'), MinigamePhase.setup);
    });
  });

  group('nextJudgeIndex (round-robin rotation)', () {
    test('advances within range and wraps around', () {
      expect(nextJudgeIndex(currentIndex: 0, participantCount: 3), 1);
      expect(nextJudgeIndex(currentIndex: 1, participantCount: 3), 2);
      expect(nextJudgeIndex(currentIndex: 2, participantCount: 3), 0);
    });

    test('single-player sessions rotate to self', () {
      expect(nextJudgeIndex(currentIndex: 0, participantCount: 1), 0);
    });

    test('rejects a non-positive participant count', () {
      expect(
        () => nextJudgeIndex(currentIndex: 0, participantCount: 0),
        throwsArgumentError,
      );
      expect(
        () => nextJudgeIndex(currentIndex: 0, participantCount: -1),
        throwsArgumentError,
      );
    });
  });

  group('randomParticipantIndex', () {
    test('stays in [0, participantCount) for a seeded rng', () {
      final rng = Random(42);
      for (var i = 0; i < 100; i++) {
        final idx = randomParticipantIndex(participantCount: 4, rng: rng);
        expect(idx, inInclusiveRange(0, 3));
      }
    });

    test('is deterministic for a seeded rng', () {
      expect(
        randomParticipantIndex(participantCount: 4, rng: Random(7)),
        randomParticipantIndex(participantCount: 4, rng: Random(7)),
      );
    });

    test('rejects a non-positive participant count', () {
      expect(
        () => randomParticipantIndex(participantCount: 0, rng: Random(1)),
        throwsArgumentError,
      );
    });
  });

  group('GameTurnSkeleton.fromJson', () {
    test('parses a full skeleton', () {
      final skeleton = GameTurnSkeleton.fromJson({
        'judge_index': 2,
        'round': 4,
        'phase': 'playing',
        'subject_id': 'sub-1',
        'prompt_type': 'verdad',
        'prompt': {'id': 'p-1', 'body': '¿Cuál fue tu primer beso?'},
      });

      expect(skeleton.judgeIndex, 2);
      expect(skeleton.round, 4);
      expect(skeleton.phase, MinigamePhase.playing);
      expect(skeleton.subjectId, 'sub-1');
      expect(skeleton.promptType, 'verdad');
      expect(skeleton.prompt?['body'], '¿Cuál fue tu primer beso?');
      expect(skeleton.isFinished, isFalse);
      expect(skeleton.hasPrompt, isTrue);
    });

    test('tolerates missing keys (defaults)', () {
      final skeleton = GameTurnSkeleton.fromJson(const {});

      expect(skeleton.judgeIndex, 0);
      expect(skeleton.round, 0);
      expect(skeleton.phase, MinigamePhase.setup);
      expect(skeleton.subjectId, isNull);
      expect(skeleton.promptType, isNull);
      expect(skeleton.prompt, isNull);
      expect(skeleton.hasPrompt, isFalse);
    });

    test('coerces numeric strings to ints when present', () {
      final skeleton = GameTurnSkeleton.fromJson({
        'judge_index': '3',
        'round': '1',
        'phase': 'finished',
      });

      expect(skeleton.judgeIndex, 3);
      expect(skeleton.round, 1);
      expect(skeleton.isFinished, isTrue);
    });
  });

  group('GameRoundRecord', () {
    test('toJson emits the wire shape for p_round', () {
      final record = GameRoundRecord(
        subjectId: 'sub-1',
        promptType: 'reto',
        promptId: 'p-1',
        outcome: PromptOutcome.done,
        at: DateTime.utc(2026, 8, 28, 12),
      );

      final json = record.toJson();
      expect(json['subject_id'], 'sub-1');
      expect(json['prompt_type'], 'reto');
      expect(json['prompt_id'], 'p-1');
      expect(json['outcome'], 'done');
    });

    test('fromJson round-trips and maps skip', () {
      final record = GameRoundRecord.fromJson({
        'subject_id': 'sub-2',
        'outcome': 'skip',
        'at': '2026-08-28T12:00:00Z',
      });

      expect(record.subjectId, 'sub-2');
      expect(record.outcome, PromptOutcome.skip);
    });
  });

  group('MinigameGameState.fromRow', () {
    Map<String, dynamic> row({
      Map<String, dynamic> skeleton = const {
        'judge_index': 0,
        'round': 0,
        'phase': 'playing',
        'subject_id': 'sub-1',
      },
      List<Map<String, dynamic>> rounds = const [],
    }) {
      return {
        'session_id': 's-1',
        'game_type': 'truth_dare',
        'state': skeleton,
        'rounds': rounds,
        'created_at': '2026-08-28T10:00:00Z',
        'updated_at': '2026-08-28T10:05:00Z',
      };
    }

    test('extracts the nested turn skeleton', () {
      final game = MinigameGameState.fromRow(row());

      expect(game.sessionId, 's-1');
      expect(game.gameType, 'truth_dare');
      expect(game.skeleton.phase, MinigamePhase.playing);
      expect(game.skeleton.subjectId, 'sub-1');
      expect(game.isFinished, isFalse);
    });

    test('parses the append-only round history', () {
      final game = MinigameGameState.fromRow(
        row(rounds: [
          {'subject_id': 'sub-1', 'outcome': 'done'},
          {'subject_id': 'sub-2', 'outcome': 'skip'},
        ]),
      );

      expect(game.rounds, hasLength(2));
      expect(game.rounds.first.subjectId, 'sub-1');
      expect(game.rounds.last.outcome, PromptOutcome.skip);
    });

    test('tolerates an empty/malformed row', () {
      final game = MinigameGameState.fromRow(const {});

      expect(game.sessionId, '');
      expect(game.gameType, '');
      expect(game.skeleton.phase, MinigamePhase.setup);
      expect(game.rounds, isEmpty);
    });

    test('finished phase surfaces via isFinished', () {
      final game = MinigameGameState.fromRow(
        row(skeleton: const {
          'judge_index': 0,
          'round': 5,
          'phase': 'finished',
        }),
      );

      expect(game.isFinished, isTrue);
    });
  });
}

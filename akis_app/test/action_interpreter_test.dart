import 'package:flutter_test/flutter_test.dart';

import 'package:akis_app/core/action_interpreter.dart';
import 'package:akis_app/models/flow_item.dart';

void main() {
  const interpreter = ActionInterpreter();

  test('Türkçe hatırlatmadan tarih, saat ve amacı çıkarır', () {
    final proposal = interpreter
        .interpret(
          'Bana yarın 17.45 de su içmeyi hatırlat',
          now: DateTime(2026, 7, 15, 12),
        )
        .single;

    expect(proposal.draft.kind, FlowKind.reminder);
    expect(proposal.draft.title, 'Su içmeyi');
    expect(proposal.draft.scheduledAt, DateTime(2026, 7, 16, 17, 45));
    expect(proposal.confidence, .93);
  });

  test('zamansız hatırlatmada netleştirici soru üretir', () {
    final proposal = interpreter
        .interpret('Bana su içmeyi hatırlat', now: DateTime(2026, 7, 15))
        .single;

    expect(proposal.draft.scheduledAt, isNull);
    expect(proposal.questions, ['Ne zaman hatırlatmalıyım?']);
  });

  test('bildirim yolla ifadesini hatırlatma olarak yorumlar', () {
    final proposal = interpreter
        .interpret(
          'Saat bildirim yolla 18.05',
          now: DateTime(2026, 7, 15, 18, 2),
        )
        .single;

    expect(proposal.draft.kind, FlowKind.reminder);
    expect(proposal.draft.title, 'Saat bildirimi');
    expect(proposal.draft.scheduledAt, DateTime(2026, 7, 15, 18, 5));
  });

  test('saat ekinden kalan kesme işaretini kart başlığına taşımaz', () {
    final proposal = interpreter
        .interpret("19.16'da bildirim yolla", now: DateTime(2026, 7, 15, 19))
        .single;

    expect(proposal.draft.title, 'Bildirim yolla');
  });

  test('geçmiş veya aynı dakikadaki zamanı yarına taşır', () {
    final proposal = interpreter
        .interpret(
          'Bugün 18.02 bildirim yolla',
          now: DateTime(2026, 7, 15, 18, 2),
        )
        .single;

    expect(proposal.draft.scheduledAt, DateTime(2026, 7, 16, 18, 2));
    expect(proposal.questions.single, contains('yarın aynı saate'));
  });

  test('verilen sözü açık döngü olarak işaretler', () {
    final proposal = interpreter
        .interpret('Ece’ye bu hafta döneceğim', now: DateTime(2026, 7, 15))
        .single;

    expect(proposal.draft.kind, FlowKind.task);
    expect(proposal.draft.note, 'Açık döngü olarak saklandı');
  });

  test('dakika sonra ifadesini yerel hatırlatma zamanına çevirir', () {
    final proposal = interpreter
        .interpret(
          "2 dakika sonra Ece'ye döneceğim",
          now: DateTime(2026, 7, 15, 21, 30),
        )
        .single;

    expect(proposal.draft.kind, FlowKind.reminder);
    expect(proposal.draft.title, "Ece'ye döneceğim");
    expect(proposal.draft.scheduledAt, DateTime(2026, 7, 15, 21, 32));
  });

  test('konuşma dilindeki sayı ile göreli zamanı çözer', () {
    final proposal = interpreter
        .interpret(
          'iki dakika sonra su içmeyi hatırlat',
          now: DateTime(2026, 7, 15, 21, 30),
        )
        .single;

    expect(proposal.draft.scheduledAt, DateTime(2026, 7, 15, 21, 32));
  });

  test('yarın sabah için seçtiği varsayılan saati açıklar', () {
    final proposal = interpreter
        .interpret('yarın sabah Ece’yi ara', now: DateTime(2026, 7, 15, 21, 30))
        .single;

    expect(proposal.draft.kind, FlowKind.reminder);
    expect(proposal.draft.scheduledAt, DateTime(2026, 7, 16, 9));
    expect(proposal.questions.single, contains('09:00'));
  });

  test('geçmişte kalan akşamı ertesi güne taşır', () {
    final proposal = interpreter
        .interpret('akşam Ece’ye dön', now: DateTime(2026, 7, 15, 21, 30))
        .single;

    expect(proposal.draft.scheduledAt, DateTime(2026, 7, 16, 19));
    expect(proposal.questions.join(), contains('yarın aynı saate'));
  });

  test('çeyrek kala zamanını çözer', () {
    final proposal = interpreter
        .interpret(
          "beşe çeyrek kala Ece'yi ara",
          now: DateTime(2026, 7, 15, 10),
        )
        .single;

    expect(proposal.draft.scheduledAt, DateTime(2026, 7, 15, 16, 45));
  });

  test('virgülle ayrılan bağımsız talimatları ayrı kartlara böler', () {
    final proposals = interpreter.interpret(
      'Ece’yi ara, sunumu gözden geçir',
      now: DateTime(2026, 7, 15),
    );

    expect(proposals, hasLength(2));
    expect(proposals.map((item) => item.draft.title), [
      'Ece’yi ara',
      'Sunumu gözden geçir',
    ]);
  });
}

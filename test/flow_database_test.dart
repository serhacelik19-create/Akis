import 'package:flutter_test/flutter_test.dart';

import 'package:akis_app/data/flow_database.dart';
import 'package:akis_app/models/flow_item.dart';

void main() {
  setUpAll(() async => FlowDatabase.instance.open(inMemory: true));
  setUp(() async => FlowDatabase.instance.clear());

  test(
    'kartı SQLite içine kaydeder ve tamamlanma durumunu günceller',
    () async {
      final saved = await FlowDatabase.instance.insert(
        FlowItem(
          title: 'Yarın Ece’yi ara',
          kind: FlowKind.task,
          createdAt: DateTime(2026, 7, 15),
        ),
      );

      expect(saved.id, isNotNull);
      expect(
        (await FlowDatabase.instance.readItems()).single.title,
        'Yarın Ece’yi ara',
      );

      await FlowDatabase.instance.setDone(saved.id!, true);
      expect((await FlowDatabase.instance.readItems()).single.done, isTrue);

      await FlowDatabase.instance.delete(saved.id!);
      expect(await FlowDatabase.instance.readItems(), isEmpty);
    },
  );

  test(
    'açık döngünün sonraki kontrol zamanını saklar ve zamanı gelince bulur',
    () async {
      final now = DateTime(2026, 7, 15, 12);
      final saved = await FlowDatabase.instance.insert(
        FlowItem(
          title: 'Ece’ye dön',
          kind: FlowKind.task,
          createdAt: now,
          sourceText: 'Ece’ye bu hafta döneceğim',
          nextReviewAt: now.add(const Duration(days: 2)),
        ),
      );

      expect(
        await FlowDatabase.instance.readDueReviews(
          now: now.add(const Duration(days: 1)),
        ),
        isEmpty,
      );
      expect(
        (await FlowDatabase.instance.readDueReviews(
          now: now.add(const Duration(days: 2)),
        )).single.id,
        saved.id,
      );
    },
  );
}

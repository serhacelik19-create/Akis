import 'package:flutter_test/flutter_test.dart';

import 'package:akis_app/data/flow_database.dart';
import 'package:akis_app/models/flow_item.dart';
import 'package:akis_app/services/flow_lifecycle_service.dart';
import 'package:akis_app/services/notification_service.dart';

class _FakeNotifications implements FlowNotificationGateway {
  _FakeNotifications({this.canSchedule = true, this.throwOnCancel = false});

  final bool canSchedule;
  final bool throwOnCancel;
  final List<int> cancelled = [];
  final List<FlowItem> reminders = [];
  final List<FlowItem> reviews = [];

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    if (throwOnCancel) throw StateError('platform unavailable');
  }

  @override
  Future<void> reconcileReminders(Iterable<FlowItem> items) async {}

  @override
  Future<bool> scheduleOpenLoopReview(FlowItem item) async {
    reviews.add(item);
    return canSchedule;
  }

  @override
  Future<bool> scheduleReminder(FlowItem item) async {
    reminders.add(item);
    return canSchedule;
  }
}

void main() {
  setUpAll(() async => FlowDatabase.instance.open(inMemory: true));
  setUp(() async => FlowDatabase.instance.clear());

  test('izin reddedilse de kartı saklar ve planlanmadığını bildirir', () async {
    final notifications = _FakeNotifications(canSchedule: false);
    final service = FlowLifecycleService.forTesting(notifications);

    final result = await service.saveAll([
      FlowItem(
        title: 'Ece’yi ara',
        kind: FlowKind.reminder,
        createdAt: DateTime.now(),
        scheduledAt: DateTime.now().add(const Duration(hours: 1)),
      ),
    ]);

    expect(result.items, hasLength(1));
    expect(result.unscheduledNotificationCount, 1);
    expect(
      (await FlowDatabase.instance.readItems()).single.title,
      'Ece’yi ara',
    );
  });

  test('yeniden açılan gelecek hatırlatıcısını tekrar planlar', () async {
    final notifications = _FakeNotifications();
    final service = FlowLifecycleService.forTesting(notifications);
    final saved = await FlowDatabase.instance.insert(
      FlowItem(
        title: 'Sunumu gönder',
        kind: FlowKind.reminder,
        createdAt: DateTime.now(),
        scheduledAt: DateTime.now().add(const Duration(hours: 1)),
        done: true,
      ),
    );

    final ready = await service.toggleDone(saved);

    expect(ready, isTrue);
    expect(notifications.reminders.single.id, saved.id);
    expect((await FlowDatabase.instance.readItems()).single.done, isFalse);
  });

  test('bildirim iptali hata verse de kart kalıcı olarak silinir', () async {
    final notifications = _FakeNotifications(throwOnCancel: true);
    final service = FlowLifecycleService.forTesting(notifications);
    final saved = await FlowDatabase.instance.insert(
      FlowItem(
        title: 'Silinecek kart',
        kind: FlowKind.task,
        createdAt: DateTime.now(),
      ),
    );

    await service.delete(saved);

    expect(await FlowDatabase.instance.readItems(), isEmpty);
    expect(notifications.cancelled, [saved.id]);
  });
}

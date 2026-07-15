import '../data/flow_database.dart';
import '../models/flow_item.dart';
import 'notification_service.dart';

/// Owns durable changes to open loops. Widgets never need to decide whether a
/// notification must be scheduled, cancelled, or restored after an app restart.
class FlowLifecycleService {
  FlowLifecycleService._(this._notifications);

  static final instance = FlowLifecycleService._(NotificationService.instance);
  final FlowNotificationGateway _notifications;

  /// Keeps notification behaviour unit-testable without loading a device
  /// plugin. Production always uses [instance].
  factory FlowLifecycleService.forTesting(FlowNotificationGateway notifier) =>
      FlowLifecycleService._(notifier);

  Future<FlowSaveResult> saveAll(Iterable<FlowItem> drafts) async {
    final saved = await FlowDatabase.instance.insertAll(
      drafts.map(_withReviewWindow),
    );
    var unscheduledCount = 0;
    for (final item in saved) {
      if (!await _scheduleFutureNotifications(item)) unscheduledCount++;
    }
    return FlowSaveResult(
      items: saved,
      unscheduledNotificationCount: unscheduledCount,
    );
  }

  Future<bool> toggleDone(FlowItem item) async {
    if (item.id == null) return true;
    final done = !item.done;
    await FlowDatabase.instance.setDone(item.id!, done);
    if (done) {
      await _cancelSafely(item.id!);
      return true;
    }
    return _scheduleFutureNotifications(item.copyWith(done: false));
  }

  Future<bool> defer(FlowItem item, Duration duration) async {
    if (item.id == null) return true;
    final until = DateTime.now().add(duration);
    await FlowDatabase.instance.deferReview(item.id!, until);
    return _scheduleFutureNotifications(item.copyWith(nextReviewAt: until));
  }

  Future<void> delete(FlowItem item) async {
    if (item.id == null) return;
    await FlowDatabase.instance.delete(item.id!);
    await _cancelSafely(item.id!);
  }

  Future<void> reconcileReminders() async {
    final items = await FlowDatabase.instance.readItems();
    await _notifications.reconcileReminders(items);
  }

  Future<bool> _scheduleFutureNotifications(FlowItem item) async {
    final now = DateTime.now();
    if (item.done) return true;
    try {
      if (item.kind == FlowKind.reminder &&
          item.scheduledAt != null &&
          item.scheduledAt!.isAfter(now)) {
        return await _notifications.scheduleReminder(item);
      }
      if (item.nextReviewAt != null && item.nextReviewAt!.isAfter(now)) {
        return await _notifications.scheduleOpenLoopReview(item);
      }
      return true;
    } catch (_) {
      // The card is durable. A later app launch will reconcile it again.
      return false;
    }
  }

  Future<void> _cancelSafely(int id) async {
    try {
      await _notifications.cancel(id);
    } catch (_) {
      // SQLite is the source of truth; reconciliation removes a stale OS
      // notification on the next launch if a platform call fails now.
    }
  }

  FlowItem _withReviewWindow(FlowItem item) {
    if (item.done ||
        item.nextReviewAt != null ||
        item.kind == FlowKind.reminder ||
        item.note != 'Açık döngü olarak saklandı') {
      return item;
    }
    return item.copyWith(
      nextReviewAt: DateTime.now().add(const Duration(days: 2)),
    );
  }
}

class FlowSaveResult {
  const FlowSaveResult({
    required this.items,
    required this.unscheduledNotificationCount,
  });

  final List<FlowItem> items;
  final int unscheduledNotificationCount;
}

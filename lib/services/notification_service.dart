import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/flow_item.dart';

abstract interface class FlowNotificationGateway {
  Future<bool> scheduleReminder(FlowItem item);
  Future<bool> scheduleOpenLoopReview(FlowItem item);
  Future<void> cancel(int id);
  Future<void> reconcileReminders(Iterable<FlowItem> items);
}

class NotificationService implements FlowNotificationGateway {
  NotificationService._();

  static final instance = NotificationService._();
  final _notifications = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> initialize() async {
    if (_ready) return;
    tz_data.initializeTimeZones();
    try {
      final timezone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timezone.identifier));
    } catch (_) {
      // A UTC fallback is safer than failing to save the user's card.
    }

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
      macOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _notifications.initialize(settings: settings);
    _ready = true;
  }

  Future<bool> requestPermission() async {
    await initialize();
    if (Platform.isMacOS) {
      return await _notifications
              .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    if (Platform.isIOS) {
      return await _notifications
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    if (Platform.isAndroid) {
      return await _notifications
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          true;
    }
    return true;
  }

  @override
  Future<bool> scheduleReminder(FlowItem item) async {
    final when = item.scheduledAt;
    if (item.id == null || when == null || item.kind != FlowKind.reminder) {
      return false;
    }
    if (!await requestPermission()) return false;
    await _schedule(
      id: item.id!,
      when: when,
      title: 'Akış hatırlatması',
      body: item.title,
      payload: 'flow_item:${item.id}',
    );
    return true;
  }

  @override
  Future<bool> scheduleOpenLoopReview(FlowItem item) async {
    final when = item.nextReviewAt;
    if (item.id == null || when == null || item.done) return false;
    if (!await requestPermission()) return false;
    await _schedule(
      id: _reviewNotificationId(item.id!),
      when: when,
      title: 'Akış hafızası',
      body: 'Bunu yeniden açmak ister misin? ${item.title}',
      payload: 'flow_review:${item.id}',
    );
    return true;
  }

  Future<void> _schedule({
    required int id,
    required DateTime when,
    required String title,
    required String body,
    required String payload,
  }) async {
    await _notifications.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(when, tz.local),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'akis_reminders',
          'Akış hatırlatmaları',
          channelDescription: 'Akış tarafından planlanan kişisel hatırlatmalar',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
        macOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: payload,
    );
  }

  /// Rebuilds the operating system's pending notifications from the local
  /// database. It is safe to call on every launch: notification ids are the
  /// SQLite ids, so a card can never create duplicate alerts.
  @override
  Future<void> reconcileReminders(Iterable<FlowItem> items) async {
    await initialize();
    final now = DateTime.now();
    final reminderPlans = items
        .where(
          (item) =>
              item.id != null &&
              !item.done &&
              item.kind == FlowKind.reminder &&
              item.scheduledAt != null &&
              item.scheduledAt!.isAfter(now),
        )
        .map(
          (item) => _NotificationPlan(
            id: item.id!,
            when: item.scheduledAt!,
            title: 'Akış hatırlatması',
            body: item.title,
            payload: 'flow_item:${item.id}',
          ),
        );
    final reviewPlans = items
        .where(
          (item) =>
              item.id != null &&
              !item.done &&
              item.nextReviewAt != null &&
              item.nextReviewAt!.isAfter(now),
        )
        .map(
          (item) => _NotificationPlan(
            id: _reviewNotificationId(item.id!),
            when: item.nextReviewAt!,
            title: 'Akış hafızası',
            body: 'Bunu yeniden açmak ister misin? ${item.title}',
            payload: 'flow_review:${item.id}',
          ),
        );
    final desired = [...reminderPlans, ...reviewPlans];
    final desiredIds = desired.map((item) => item.id).toSet();
    final pending = await _notifications.pendingNotificationRequests();
    for (final request in pending) {
      if ((request.payload?.startsWith('flow_item:') == true ||
              request.payload?.startsWith('flow_review:') == true) &&
          !desiredIds.contains(request.id)) {
        await _notifications.cancel(id: request.id);
      }
    }
    if (desired.isEmpty) return;

    // Requesting a previously granted permission is idempotent. If it was
    // denied, we keep the user's card and simply leave it unscheduled.
    if (!await requestPermission()) return;
    for (final item in desired) {
      // Overwriting the same id also repairs an edited time after a restart.
      await _schedule(
        id: item.id,
        when: item.when,
        title: item.title,
        body: item.body,
        payload: item.payload,
      );
    }
  }

  @override
  Future<void> cancel(int id) async {
    await initialize();
    await _notifications.cancel(id: id);
    await _notifications.cancel(id: _reviewNotificationId(id));
  }

  int _reviewNotificationId(int flowItemId) => 1000000 + flowItemId;
}

class _NotificationPlan {
  const _NotificationPlan({
    required this.id,
    required this.when,
    required this.title,
    required this.body,
    required this.payload,
  });

  final int id;
  final DateTime when;
  final String title;
  final String body;
  final String payload;
}

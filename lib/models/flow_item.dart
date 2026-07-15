import 'package:flutter/material.dart';

enum FlowKind { task, reminder, note, list }

extension FlowKindDetails on FlowKind {
  String get label => switch (this) {
    FlowKind.task => 'Görev',
    FlowKind.reminder => 'Hatırlatma',
    FlowKind.note => 'Not',
    FlowKind.list => 'Liste',
  };

  IconData get icon => switch (this) {
    FlowKind.task => Icons.check_circle_outline_rounded,
    FlowKind.reminder => Icons.alarm_rounded,
    FlowKind.note => Icons.sticky_note_2_rounded,
    FlowKind.list => Icons.format_list_bulleted_rounded,
  };

  Color get tint => switch (this) {
    FlowKind.task => const Color(0xFFA9F0CE),
    FlowKind.reminder => const Color(0xFFFFD98E),
    FlowKind.note => const Color(0xFFFFB9AC),
    FlowKind.list => const Color(0xFFC8BCFF),
  };
}

class FlowItem {
  const FlowItem({
    this.id,
    required this.title,
    required this.kind,
    required this.createdAt,
    this.scheduledAt,
    this.note,
    this.sourceText,
    this.nextReviewAt,
    this.lastPromptedAt,
    this.done = false,
  });

  final int? id;
  final String title;
  final FlowKind kind;
  final DateTime createdAt;
  final DateTime? scheduledAt;
  final String? note;

  /// The original sentence is retained locally so future UI can explain why
  /// an open loop exists without sending the user's data anywhere.
  final String? sourceText;
  final DateTime? nextReviewAt;
  final DateTime? lastPromptedAt;
  final bool done;

  FlowItem copyWith({
    String? title,
    DateTime? scheduledAt,
    String? note,
    String? sourceText,
    DateTime? nextReviewAt,
    DateTime? lastPromptedAt,
    bool? done,
  }) => FlowItem(
    id: id,
    title: title ?? this.title,
    kind: kind,
    createdAt: createdAt,
    scheduledAt: scheduledAt ?? this.scheduledAt,
    note: note ?? this.note,
    sourceText: sourceText ?? this.sourceText,
    nextReviewAt: nextReviewAt ?? this.nextReviewAt,
    lastPromptedAt: lastPromptedAt ?? this.lastPromptedAt,
    done: done ?? this.done,
  );
}

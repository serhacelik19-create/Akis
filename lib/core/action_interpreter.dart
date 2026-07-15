import '../models/flow_item.dart';

class ActionProposal {
  const ActionProposal({
    required this.draft,
    required this.confidence,
    this.questions = const [],
  });

  final FlowItem draft;
  final double confidence;
  final List<String> questions;

  ActionProposal copyWith({FlowItem? draft}) => ActionProposal(
    draft: draft ?? this.draft,
    confidence: confidence,
    questions: questions,
  );
}

class ActionInterpreter {
  const ActionInterpreter();

  List<ActionProposal> interpret(String input, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final segments = input
        .split(RegExp(r'\s*[,;]\s*'))
        .where((segment) => segment.trim().isNotEmpty)
        .toList();
    if (segments.length > 1) {
      return segments
          .expand((segment) => interpret(segment, now: reference))
          .toList();
    }
    return [_interpretOne(input, reference)];
  }

  ActionProposal _interpretOne(String input, DateTime reference) {
    final lower = _normalize(input);
    final kind = _kindFor(lower);
    final schedule = _scheduledAt(lower, reference);
    final title = _titleFor(input, lower, kind);
    final memoryCue = _memoryCue(lower, kind);
    final questions = <String>[];
    if (kind == FlowKind.reminder && schedule == null) {
      questions.add('Ne zaman hatırlatmalıyım?');
    }
    if (schedule?.movedToTomorrow == true) {
      questions.add(
        'Bu saat geçti; yarın aynı saate aldım. Düzenleyebilirsin.',
      );
    }
    if (schedule?.assumedTime == true) {
      questions.add('Saati ${_clock(schedule!.value)} olarak önerdim.');
    }

    return ActionProposal(
      draft: FlowItem(
        title: title,
        kind: kind,
        createdAt: reference,
        scheduledAt: schedule?.value,
        note: memoryCue,
        sourceText: input,
      ),
      confidence: schedule == null
          ? .74
          : schedule.assumedTime
          ? .79
          : .93,
      questions: questions,
    );
  }

  FlowKind _kindFor(String lower) {
    if (RegExp(
      r'(?<!\d)\d+\s*(?:dakika|dk|saat|gün)\s+sonra',
    ).hasMatch(lower)) {
      return FlowKind.reminder;
    }
    if (RegExp(
      r'\b(?:bugün|yarın|haftaya|sabah|öğlen|öğleden sonra|akşam|gece|pazartesi|salı|çarşamba|perşembe|cuma|cumartesi|pazar)\b',
    ).hasMatch(lower)) {
      return FlowKind.reminder;
    }
    if (lower.contains('liste') || lower.contains('alışveriş')) {
      return FlowKind.list;
    }
    if (lower.contains('not ') ||
        lower.startsWith('not') ||
        lower.contains('fikir')) {
      return FlowKind.note;
    }
    if (lower.contains('hatırlat') ||
        lower.contains('alarm') ||
        lower.contains('bildirim') ||
        lower.contains('uyar')) {
      return FlowKind.reminder;
    }
    return FlowKind.task;
  }

  String? _memoryCue(String lower, FlowKind kind) {
    if (kind == FlowKind.note) return 'Saklanan düşünce';
    if (kind == FlowKind.reminder) return 'Zamanı gelince sana dönecek';
    if (lower.contains('söz verd') ||
        lower.contains('döneceğ') ||
        lower.contains('halletmem lazım') ||
        lower.contains('sonra bak') ||
        lower.contains('unutma')) {
      return 'Açık döngü olarak saklandı';
    }
    return null;
  }

  _ParsedSchedule? _scheduledAt(String lower, DateTime reference) {
    final relative = RegExp(
      r'(?<!\w)(\d+|bir|iki|üç|dört|beş|altı|yedi|sekiz|dokuz|on|on bir|on iki)\s*(dakika|dk|saat|gün)\s+sonra',
    ).firstMatch(lower);
    if (relative != null) {
      final amount = _numberValue(relative.group(1)!);
      final unit = relative.group(2)!;
      final duration = switch (unit) {
        'dakika' || 'dk' => Duration(minutes: amount),
        'saat' => Duration(hours: amount),
        _ => Duration(days: amount),
      };
      return _ParsedSchedule(reference.add(duration));
    }

    final quarter = RegExp(
      r'\b(\d{1,2}|bir|iki|üç|dört|beş|altı|yedi|sekiz|dokuz|on)(?:e|a|ye|ya)?\s+çeyrek\s+kala\b',
    ).firstMatch(lower);
    if (quarter != null) {
      var targetHour = _numberValue(quarter.group(1)!);
      if (targetHour <= 7 &&
          !lower.contains('sabah') &&
          !lower.contains('gece')) {
        targetHour += 12;
      }
      final hour = targetHour - 1;
      return _timeOnMentionedDay(lower, reference, hour < 0 ? 23 : hour, 45);
    }

    final half = RegExp(
      r'\b(\d{1,2}|bir|iki|üç|dört|beş|altı|yedi|sekiz|dokuz|on)\s+buçuk\b',
    ).firstMatch(lower);
    if (half != null) {
      return _timeOnMentionedDay(
        lower,
        reference,
        _numberValue(half.group(1)!),
        30,
      );
    }

    final match =
        RegExp(
          r'(?<!\d)([01]?\d|2[0-3])\s*[.:]\s*([0-5]\d)(?!\d)',
        ).firstMatch(lower) ??
        RegExp(r'saat\s+([01]?\d|2[0-3])\b').firstMatch(lower);
    if (match != null) {
      final hour = int.parse(match.group(1)!);
      final minute = match.groupCount >= 2 && match.group(2) != null
          ? int.parse(match.group(2)!)
          : 0;
      return _timeOnMentionedDay(lower, reference, hour, minute);
    }

    final wordClock = RegExp(
      r'\bsaat\s+(bir|iki|üç|dört|beş|altı|yedi|sekiz|dokuz|on|on bir|on iki)\b',
    ).firstMatch(lower);
    if (wordClock != null) {
      return _timeOnMentionedDay(
        lower,
        reference,
        _numberValue(wordClock.group(1)!),
        0,
      );
    }

    final period = _periodHour(lower);
    if (period != null) {
      final day = _dayFor(lower, reference, period);
      var candidate = DateTime(day.year, day.month, day.day, period);
      var movedToTomorrow = false;
      if (!candidate.isAfter(reference) && !lower.contains('yarın')) {
        candidate = candidate.add(const Duration(days: 1));
        movedToTomorrow = true;
      }
      return _ParsedSchedule(
        candidate,
        assumedTime: true,
        movedToTomorrow: movedToTomorrow,
      );
    }
    return null;
  }

  _ParsedSchedule _timeOnMentionedDay(
    String lower,
    DateTime reference,
    int hour,
    int minute,
  ) {
    final day = _dayFor(lower, reference, hour);
    var candidate = DateTime(day.year, day.month, day.day, hour, minute);
    if (!candidate.isAfter(reference) && !lower.contains('yarın')) {
      candidate = candidate.add(const Duration(days: 1));
      return _ParsedSchedule(candidate, movedToTomorrow: true);
    }
    return _ParsedSchedule(candidate);
  }

  DateTime _dayFor(String lower, DateTime reference, int hour) {
    if (lower.contains('yarın')) return reference.add(const Duration(days: 1));
    final weekdays = <String, int>{
      'pazartesi': DateTime.monday,
      'salı': DateTime.tuesday,
      'çarşamba': DateTime.wednesday,
      'perşembe': DateTime.thursday,
      'cuma': DateTime.friday,
      'cumartesi': DateTime.saturday,
      'pazar': DateTime.sunday,
    };
    for (final entry in weekdays.entries) {
      if (lower.contains(entry.key)) {
        var days = (entry.value - reference.weekday) % 7;
        if (days == 0 && hour <= reference.hour) days = 7;
        if (lower.contains('haftaya')) days += 7;
        return reference.add(Duration(days: days));
      }
    }
    return DateTime(reference.year, reference.month, reference.day);
  }

  int? _periodHour(String lower) {
    if (lower.contains('öğleden sonra')) return 15;
    if (lower.contains('sabah')) return 9;
    if (lower.contains('öğlen')) return 12;
    if (lower.contains('akşam')) return 19;
    if (lower.contains('gece')) return 21;
    return null;
  }

  int _numberValue(String raw) {
    final normalized = raw.trim().toLowerCase();
    final numeric = int.tryParse(normalized);
    if (numeric != null) return numeric;
    const values = {
      'bir': 1,
      'iki': 2,
      'üç': 3,
      'dört': 4,
      'beş': 5,
      'altı': 6,
      'yedi': 7,
      'sekiz': 8,
      'dokuz': 9,
      'on': 10,
      'on bir': 11,
      'on iki': 12,
    };
    return values[normalized] ?? 0;
  }

  String _normalize(String input) => input
      .toLowerCase()
      .replaceAll('’', "'")
      .replaceAll('bi ', 'bir ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  String _clock(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  String _titleFor(String input, String lower, FlowKind kind) {
    if (kind == FlowKind.note) {
      return input
          .replaceFirst(
            RegExp(r'^\s*(?:not|yeni fikir)\s*:\s*', caseSensitive: false),
            '',
          )
          .trim();
    }

    var title = input
        .replaceAll(
          RegExp(
            r'(?<!\w)(?:\d+|bir|iki|üç|dört|beş|altı|yedi|sekiz|dokuz|on|on bir|on iki)\s*(?:dakika|dk|saat|gün)\s+sonra',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'\b(?:yarın|bugün|haftaya|sabah|öğlen|öğleden sonra|akşam|gece)\b',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(r'(?<!\d)([01]?\d|2[0-3])\s*[.:]\s*([0-5]\d)(?!\d)'),
          '',
        )
        .replaceAll(
          RegExp(r'\bsaat\s+([01]?\d|2[0-3])\b', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'\b(?:bugün|yarın|bana|beni)\b', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\bhatırlatma\s+yap\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bhatırlat\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\b(?:de|da|te|ta)\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceFirst(RegExp(r"^[\s'’`.,;:!?-]+"), '')
        .replaceFirst(RegExp(r"[\s'’`.,;:!?-]+$"), '')
        .trim();

    if (kind == FlowKind.list && title.toLowerCase().contains('alışveriş')) {
      title = 'Alışveriş listesi';
    }
    if (kind == FlowKind.reminder &&
        RegExp(
          r'^saat\s+bildirim\s+yolla$',
          caseSensitive: false,
        ).hasMatch(title)) {
      title = 'Saat bildirimi';
    }
    if (title.isEmpty) {
      return switch (kind) {
        FlowKind.reminder => 'Hatırlatma',
        FlowKind.list => 'Yeni liste',
        FlowKind.note => 'Yeni not',
        FlowKind.task => input,
      };
    }
    return title[0].toUpperCase() + title.substring(1);
  }
}

class _ParsedSchedule {
  const _ParsedSchedule(
    this.value, {
    this.movedToTomorrow = false,
    this.assumedTime = false,
  });
  final DateTime value;
  final bool movedToTomorrow;
  final bool assumedTime;
}

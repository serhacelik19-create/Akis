import 'dart:io';

import 'package:flutter/material.dart';

import 'core/action_interpreter.dart';
import 'data/flow_database.dart';
import 'models/flow_item.dart';
import 'services/audio_capture_service.dart';
import 'services/device_speech_service.dart';
import 'services/flow_lifecycle_service.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlowDatabase.instance.open();
  await NotificationService.instance.initialize();
  // A restart must not make a future reminder disappear from the device.
  try {
    await FlowLifecycleService.instance.reconcileReminders();
  } catch (_) {
    // A notification permission or platform problem never prevents the user
    // from opening their locally stored memory.
  }
  runApp(const AkisApp());
}

class AkisApp extends StatelessWidget {
  const AkisApp({super.key});

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF1E2935);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Akış',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFFFFCF8),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6D5CE8),
          brightness: Brightness.light,
          surface: const Color(0xFFFFFFFF),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFFFFFCF8),
          indicatorColor: Color(0xFFFFD8D2),
          iconTheme: WidgetStatePropertyAll(
            IconThemeData(color: Color(0xFF37453F)),
          ),
        ),
        textTheme: ThemeData.light().textTheme.apply(
          fontFamily: 'Arial',
          bodyColor: ink,
          displayColor: ink,
        ),
      ),
      home: const FlowHome(),
    );
  }
}

class FlowHome extends StatefulWidget {
  const FlowHome({super.key});

  @override
  State<FlowHome> createState() => _FlowHomeState();
}

class _FlowHomeState extends State<FlowHome> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  bool _isRecording = false;
  bool _isPlanning = false;
  String? _planningStatus;
  bool _isLoading = true;
  int _selectedPage = 0;
  final _interpreter = const ActionInterpreter();
  final _audioCapture = AudioCaptureService();
  List<ActionProposal> _proposals = [];
  List<FlowItem> _items = [];
  FlowItem? _dueReview;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    final items = await FlowDatabase.instance.readItems();
    final due = await FlowDatabase.instance.readDueReviews();
    if (!mounted) return;
    setState(() {
      _items = items;
      _dueReview = due.isEmpty ? null : due.first;
      _isLoading = false;
    });
  }

  @override
  void dispose() {
    _audioCapture.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _planFromInput() async {
    final value = _input.text.trim();
    if (value.isEmpty) {
      _focus.requestFocus();
      return;
    }
    setState(() {
      _isPlanning = true;
      _planningStatus = 'Plan hazırlanıyor…';
    });
    try {
      final proposals = await _proposalsFor(value);
      if (!mounted) return;
      setState(() => _proposals = proposals);
    } finally {
      if (mounted) {
        setState(() {
          _isPlanning = false;
          _planningStatus = null;
        });
      }
    }
  }

  Future<void> _recordOrProcessAudio() async {
    if (_isPlanning) return;
    if (!_isRecording) {
      try {
        await _audioCapture.start();
        if (mounted) setState(() => _isRecording = true);
      } on AudioCaptureException catch (error) {
        _showMessage(error.message);
      } catch (_) {
        _showMessage('Ses kaydı başlatılamadı. Mikrofon iznini kontrol et.');
      }
      return;
    }

    setState(() {
      _isRecording = false;
      _isPlanning = true;
      _planningStatus = 'Ses kaydı sonlandırılıyor…';
    });
    File? audioFile;
    try {
      audioFile = await _audioCapture.stop();
      if (audioFile == null) {
        _showMessage('Ses kaydı alınamadı.');
        return;
      }
      if (mounted) {
        setState(() => _planningStatus = 'Cihazın konuşma tanıması dinliyor…');
      }
      final transcript = await DeviceSpeechService.transcribe(audioFile);
      if (mounted) setState(() => _planningStatus = 'Plan hazırlanıyor…');
      final proposals = await _proposalsFor(transcript);
      if (!mounted) return;
      setState(() {
        _input.text = transcript;
        _proposals = proposals;
      });
      if (proposals.isEmpty) {
        _showMessage('Bu kayıttan net bir eylem çıkaramadım.');
      }
    } on AudioCaptureException catch (error) {
      _showMessage(error.message);
    } on DeviceSpeechException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage('Ses işlenirken beklenmeyen bir sorun oluştu.');
    } finally {
      if (audioFile != null) {
        try {
          await audioFile.delete();
        } on FileSystemException {
          // A cache cleanup problem must not hide a successful transcription.
        }
      }
      if (mounted) {
        setState(() {
          _isPlanning = false;
          _planningStatus = null;
        });
      }
    }
  }

  Future<List<ActionProposal>> _proposalsFor(String input) async {
    return _interpreter.interpret(input);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _applyProposals(List<FlowItem> drafts) async {
    try {
      final result = await FlowLifecycleService.instance.saveAll(drafts);
      final saved = result.items;
      final reminders = saved
          .where((item) => item.kind == FlowKind.reminder)
          .toList();
      if (!mounted) return;
      setState(() {
        _items = [...saved, ..._items];
        _proposals = [];
        _input.clear();
      });
      if (reminders.isNotEmpty && result.unscheduledNotificationCount == 0) {
        _showMessage('Hatırlatma cihazına planlandı.');
      } else if (result.unscheduledNotificationCount > 0) {
        _showMessage(
          'Kart kaydedildi; bildirim izni veya cihaz ayarını kontrol et.',
        );
      }
    } catch (_) {
      _showMessage('Kartlar kaydedilemedi. Lütfen tekrar dene.');
    }
  }

  Future<void> _toggleDone(FlowItem item) async {
    if (item.id == null) return;
    try {
      final notificationReady = await FlowLifecycleService.instance.toggleDone(
        item,
      );
      if (!mounted) return;
      final updated = item.copyWith(done: !item.done);
      setState(
        () => _items = _items
            .map((entry) => entry.id == item.id ? updated : entry)
            .toList(),
      );
      if (!updated.done && !notificationReady) {
        _showMessage('Kart açıldı; bildirim için cihaz iznini kontrol et.');
      }
    } catch (_) {
      _showMessage('Kart durumu güncellenemedi. Lütfen tekrar dene.');
    }
  }

  Future<void> _deferDueReview(FlowItem item) async {
    try {
      final notificationReady = await FlowLifecycleService.instance.defer(
        item,
        const Duration(days: 1),
      );
      await _loadItems();
      if (!notificationReady) {
        _showMessage('Kart ertelendi; bildirim için cihaz iznini kontrol et.');
      }
    } catch (_) {
      _showMessage('Kart ertelenemedi. Lütfen tekrar dene.');
    }
  }

  Future<void> _completeDueReview(FlowItem item) async {
    await _toggleDone(item);
    await _loadItems();
  }

  Future<void> _deleteItem(FlowItem item) async {
    try {
      await FlowLifecycleService.instance.delete(item);
      if (!mounted) return;
      setState(() {
        _items = _items.where((entry) => entry.id != item.id).toList();
        if (_dueReview?.id == item.id) _dueReview = null;
      });
      _showMessage('Kart silindi.');
    } catch (_) {
      _showMessage('Kart silinemedi. Lütfen tekrar dene.');
    }
  }

  Future<void> _showSearch() async {
    var query = '';
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final normalized = query.toLowerCase().trim();
          final results = _items.where((item) {
            if (normalized.isEmpty) return true;
            return '${item.title} ${item.note ?? ''} ${item.sourceText ?? ''}'
                .toLowerCase()
                .contains(normalized);
          }).toList();
          return AlertDialog(
            title: const Text('Hafızada ara'),
            content: SizedBox(
              width: 500,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    autofocus: true,
                    onChanged: (value) => setDialogState(() => query = value),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded),
                      hintText: 'Söz, fikir veya kişi ara…',
                    ),
                  ),
                  const SizedBox(height: 14),
                  Flexible(
                    child: results.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(20),
                            child: Text('Eşleşen bir kart yok.'),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: results.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final item = results[index];
                              return ListTile(
                                leading: Icon(item.kind.icon),
                                title: Text(item.title),
                                subtitle: Text(
                                  item.done ? 'Tamamlandı' : _timeLabel(item),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Kapat'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showNotifications() async {
    final now = DateTime.now();
    final upcoming =
        _items
            .where(
              (item) =>
                  !item.done &&
                  ((item.scheduledAt?.isAfter(now) ?? false) ||
                      (item.nextReviewAt?.isAfter(now) ?? false)),
            )
            .toList()
          ..sort((a, b) {
            final aTime = a.scheduledAt ?? a.nextReviewAt!;
            final bTime = b.scheduledAt ?? b.nextReviewAt!;
            return aTime.compareTo(bTime);
          });
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Yaklaşanlar'),
        content: SizedBox(
          width: 460,
          child: upcoming.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('Şu an planlanmış bir hatırlatma yok.'),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: upcoming.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = upcoming[index];
                    final review = item.scheduledAt == null;
                    return ListTile(
                      leading: Icon(
                        review ? Icons.history_rounded : Icons.alarm_rounded,
                      ),
                      title: Text(item.title),
                      subtitle: Text(
                        review
                            ? 'Hafıza kontrolü · ${_reviewLabel(item.nextReviewAt!)}'
                            : _timeLabel(item),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Kapat'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 980;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            if (isWide)
              _SideRail(
                selectedPage: _selectedPage,
                onSelect: (page) => setState(() => _selectedPage = page),
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  isWide ? 48 : 20,
                  24,
                  isWide ? 48 : 20,
                  36,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1240),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _TopBar(
                        isWide: isWide,
                        onSearch: _showSearch,
                        onNotifications: _showNotifications,
                        notificationCount: _notificationCount,
                      ),
                      const SizedBox(height: 38),
                      _buildPage(isWide),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: isWide
          ? null
          : _MobileNav(
              selectedIndex: _selectedPage,
              onSelect: (page) => setState(() => _selectedPage = page),
            ),
    );
  }

  Widget _buildPage(bool isWide) {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.all(56),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_selectedPage == 0) {
      return _Dashboard(
        input: _input,
        focus: _focus,
        isRecording: _isRecording,
        isPlanning: _isPlanning,
        planningStatus: _planningStatus,
        proposals: _proposals,
        items: _items,
        dueReview: _dueReview,
        isWide: isWide,
        onRecord: _recordOrProcessAudio,
        onSubmit: _planFromInput,
        onApply: _applyProposals,
        onDismiss: () => setState(() => _proposals = []),
        onToggle: _toggleDone,
        onDelete: _deleteItem,
        onDeferDueReview: _deferDueReview,
        onCompleteDueReview: _completeDueReview,
      );
    }
    final config = switch (_selectedPage) {
      1 => (
        title: 'Sözlerim',
        subtitle: 'Kendine ve başkalarına verdiğin sözler.',
        kind: FlowKind.task,
      ),
      2 => (
        title: 'Zamanı gelenler',
        subtitle: 'Dönme zamanı yaklaşan açık döngüler.',
        kind: FlowKind.reminder,
      ),
      3 => (
        title: 'Fikirler',
        subtitle: 'Henüz bir yere gitmesi gerekmeyen düşünceler.',
        kind: FlowKind.note,
      ),
      _ => (
        title: 'Hafıza',
        subtitle: 'Aklından düşenleri burada bulursun.',
        kind: null,
      ),
    };
    final filtered = config.kind == null
        ? _items.where((item) => item.kind == FlowKind.note).toList()
        : _items.where((item) => item.kind == config.kind).toList();
    return _CollectionPage(
      title: config.title,
      subtitle: config.subtitle,
      items: filtered,
      emptyLabel: config.kind == FlowKind.note
          ? 'Henüz yakalanmış bir not yok.'
          : 'Burada henüz bir şey yok.',
      onToggle: _toggleDone,
      onDelete: _deleteItem,
    );
  }

  int get _notificationCount {
    final now = DateTime.now();
    return _items
        .where(
          (item) =>
              !item.done &&
              ((item.scheduledAt?.isAfter(now) ?? false) ||
                  (item.nextReviewAt?.isAfter(now) ?? false)),
        )
        .length;
  }
}

class _Dashboard extends StatelessWidget {
  const _Dashboard({
    required this.input,
    required this.focus,
    required this.isRecording,
    required this.isPlanning,
    required this.planningStatus,
    required this.proposals,
    required this.items,
    required this.dueReview,
    required this.isWide,
    required this.onRecord,
    required this.onSubmit,
    required this.onApply,
    required this.onDismiss,
    required this.onToggle,
    required this.onDelete,
    required this.onDeferDueReview,
    required this.onCompleteDueReview,
  });

  final TextEditingController input;
  final FocusNode focus;
  final bool isRecording;
  final bool isPlanning;
  final String? planningStatus;
  final List<ActionProposal> proposals;
  final List<FlowItem> items;
  final FlowItem? dueReview;
  final bool isWide;
  final VoidCallback onRecord;
  final VoidCallback onSubmit;
  final Future<void> Function(List<FlowItem>) onApply;
  final VoidCallback onDismiss;
  final Future<void> Function(FlowItem) onToggle;
  final Future<void> Function(FlowItem) onDelete;
  final Future<void> Function(FlowItem) onDeferDueReview;
  final Future<void> Function(FlowItem) onCompleteDueReview;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _HeroComposer(
        controller: input,
        focusNode: focus,
        isRecording: isRecording,
        isPlanning: isPlanning,
        planningStatus: planningStatus,
        onRecord: onRecord,
        onSubmit: onSubmit,
      ),
      if (proposals.isNotEmpty) ...[
        const SizedBox(height: 24),
        _ProposalPanel(
          proposals: proposals,
          onApply: onApply,
          onDismiss: onDismiss,
        ),
      ],
      if (dueReview != null) ...[
        const SizedBox(height: 22),
        _MemoryNudge(
          item: dueReview!,
          onDefer: () => onDeferDueReview(dueReview!),
          onComplete: () => onCompleteDueReview(dueReview!),
        ),
      ],
      const SizedBox(height: 40),
      if (isWide)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 7,
              child: _TodayFlow(
                items: items,
                onToggle: onToggle,
                onDelete: onDelete,
              ),
            ),
            const SizedBox(width: 32),
            Expanded(flex: 4, child: _RightColumn(items: items)),
          ],
        )
      else ...[
        _TodayFlow(items: items, onToggle: onToggle, onDelete: onDelete),
        const SizedBox(height: 28),
        _RightColumn(items: items),
      ],
    ],
  );
}

class _CollectionPage extends StatelessWidget {
  const _CollectionPage({
    required this.title,
    required this.subtitle,
    required this.items,
    required this.emptyLabel,
    required this.onToggle,
    required this.onDelete,
  });

  final String title;
  final String subtitle;
  final List<FlowItem> items;
  final String emptyLabel;
  final Future<void> Function(FlowItem) onToggle;
  final Future<void> Function(FlowItem) onDelete;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(
          fontSize: 34,
          fontWeight: FontWeight.w800,
          letterSpacing: -1.4,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        subtitle,
        style: const TextStyle(color: Color(0xFF788179), fontSize: 15),
      ),
      const SizedBox(height: 28),
      if (items.isEmpty)
        _EmptyState(label: emptyLabel)
      else
        ...items.map(
          (item) => _FlowCard(
            item: item,
            onTap: () => onToggle(item),
            onDelete: () => onDelete(item),
          ),
        ),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 48),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFFE6EAE5)),
    ),
    child: Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: const Color(0xFFE4EEE8),
            borderRadius: BorderRadius.circular(17),
          ),
          child: const Icon(
            Icons.auto_awesome_rounded,
            color: Color(0xFF557062),
          ),
        ),
        const SizedBox(height: 15),
        Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        const Text(
          'Ana ekranda yazarak ya da konuşarak yeni bir şey ekleyebilirsin.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF7B847E), height: 1.4),
        ),
      ],
    ),
  );
}

class _SideRail extends StatelessWidget {
  const _SideRail({required this.selectedPage, required this.onSelect});
  final int selectedPage;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xFF778078);
    return Container(
      width: 220,
      margin: const EdgeInsets.all(14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2B29),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                _LogoMark(),
                SizedBox(width: 10),
                Text(
                  'akış',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1.1,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 42),
          _RailItem(
            icon: Icons.grid_view_rounded,
            label: 'Akışım',
            selected: selectedPage == 0,
            onTap: () => onSelect(0),
          ),
          _RailItem(
            icon: Icons.check_circle_outline_rounded,
            label: 'Sözlerim',
            selected: selectedPage == 1,
            onTap: () => onSelect(1),
          ),
          _RailItem(
            icon: Icons.calendar_month_outlined,
            label: 'Zamanı gelenler',
            selected: selectedPage == 2,
            onTap: () => onSelect(2),
          ),
          _RailItem(
            icon: Icons.sticky_note_2_outlined,
            label: 'Fikirler',
            selected: selectedPage == 3,
            onTap: () => onSelect(3),
          ),
          _RailItem(
            icon: Icons.auto_awesome_outlined,
            label: 'Hafıza',
            selected: selectedPage == 4,
            onTap: () => onSelect(4),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Yerel mod açık',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Verilerin bu cihazda kalır.',
                  style: TextStyle(color: muted, fontSize: 12, height: 1.35),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Row(
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: Color(0xFFDFB28B),
                child: Text(
                  'S',
                  style: TextStyle(
                    color: Color(0xFF563E2C),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Serhat',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(Icons.more_horiz_rounded, color: muted),
            ],
          ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    this.selected = false,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: selected
            ? Colors.white.withValues(alpha: .12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: selected ? Colors.white : const Color(0xFF9DA8A0),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : const Color(0xFFB7C0BA),
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    ),
  );
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.isWide,
    required this.onSearch,
    required this.onNotifications,
    required this.notificationCount,
  });
  final bool isWide;
  final VoidCallback onSearch;
  final VoidCallback onNotifications;
  final int notificationCount;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (!isWide) ...[
        const _LogoMark(),
        const SizedBox(width: 9),
        const Text(
          'akış',
          style: TextStyle(
            fontSize: 23,
            fontWeight: FontWeight.w800,
            letterSpacing: -1,
          ),
        ),
        const Spacer(),
      ] else
        const Spacer(),
      IconButton(
        tooltip: 'Hafızada ara',
        onPressed: onSearch,
        icon: const Icon(Icons.search_rounded, color: Color(0xFF69736D)),
      ),
      const SizedBox(width: 22),
      IconButton(
        tooltip: 'Yaklaşanlar',
        onPressed: onNotifications,
        icon: Stack(
          children: [
            const Icon(
              Icons.notifications_none_rounded,
              color: Color(0xFF69736D),
            ),
            if (notificationCount > 0)
              Positioned(
                right: 1,
                top: 0,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: Color(0xFFDF7656),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(width: 18),
      Container(width: 1, height: 23, color: const Color(0xFFE0E3DF)),
      const SizedBox(width: 18),
      const Text(
        '15 Temmuz, Salı',
        style: TextStyle(
          color: Color(0xFF6F7872),
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );
}

class _HeroComposer extends StatelessWidget {
  const _HeroComposer({
    required this.controller,
    required this.focusNode,
    required this.isRecording,
    required this.isPlanning,
    required this.planningStatus,
    required this.onRecord,
    required this.onSubmit,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isRecording;
  final bool isPlanning;
  final String? planningStatus;
  final VoidCallback onRecord;
  final VoidCallback onSubmit;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(28),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFBFF4DE), Color(0xFFC7E2FF), Color(0xFFE6D2FF)],
      ),
      borderRadius: BorderRadius.circular(30),
      border: Border.all(color: const Color(0xAAFFFFFF), width: 1.4),
      boxShadow: const [
        BoxShadow(
          color: Color(0x243A7B6B),
          blurRadius: 30,
          offset: Offset(0, 16),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(
              Icons.auto_awesome_rounded,
              color: Color(0xFF4C3EB7),
              size: 18,
            ),
            SizedBox(width: 8),
            Text(
              'AÇIK DÖNGÜLERİN',
              style: TextStyle(
                color: Color(0xFF4C3EB7),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 13),
        const Text(
          'Aklından düşenleri ben tutarım.',
          style: TextStyle(
            fontSize: 31,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.45,
          ),
        ),
        const SizedBox(height: 7),
        const Text(
          'Sözleri, fikirleri ve yarım kalanları doğru zamanda sana geri getirir.',
          style: TextStyle(
            color: Color(0xFF40515F),
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(19),
            boxShadow: const [
              BoxShadow(
                color: Color(0x2437457B),
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  onSubmitted: (_) => onSubmit(),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Örn. Ece’ye bu hafta döneceğim, bunu unutma.',
                    hintStyle: TextStyle(
                      color: Color(0xFF9AA39D),
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                decoration: BoxDecoration(
                  color: isRecording
                      ? const Color(0xFFFF645D)
                      : const Color(0xFFF0EAFF),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  onPressed: isPlanning ? null : onRecord,
                  icon: Icon(
                    isRecording ? Icons.stop_rounded : Icons.mic_none_rounded,
                    color: isRecording ? Colors.white : const Color(0xFF6654CE),
                  ),
                ),
              ),
              const SizedBox(width: 7),
              FilledButton(
                onPressed: isPlanning ? null : onSubmit,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF645D),
                  minimumSize: const Size(50, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: isPlanning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.arrow_upward_rounded),
              ),
            ],
          ),
        ),
        if (isRecording)
          const Padding(
            padding: EdgeInsets.only(top: 14),
            child: Row(
              children: [
                Icon(
                  Icons.graphic_eq_rounded,
                  color: Color(0xFFBC5A40),
                  size: 18,
                ),
                SizedBox(width: 7),
                Text(
                  'Dinliyorum… bitirdiğinde durdurabilirsin.',
                  style: TextStyle(
                    color: Color(0xFF8C4A37),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        if (isPlanning && planningStatus != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  planningStatus!,
                  style: const TextStyle(
                    color: Color(0xFF4C3EB7),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _MemoryNudge extends StatelessWidget {
  const _MemoryNudge({
    required this.item,
    required this.onDefer,
    required this.onComplete,
  });

  final FlowItem item;
  final Future<void> Function() onDefer;
  final Future<void> Function() onComplete;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF8EA),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xFFF0D8A8)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: const Color(0xFFFFE3A9),
            borderRadius: BorderRadius.circular(13),
          ),
          child: const Icon(Icons.history_rounded, color: Color(0xFF9A6428)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Bunu yeniden açmak ister misin?',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const SizedBox(height: 5),
              Text(
                item.title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (item.sourceText != null) ...[
                const SizedBox(height: 4),
                Text(
                  '“${item.sourceText}”',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF7C705C),
                    height: 1.35,
                  ),
                ),
              ],
              const SizedBox(height: 13),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: onDefer,
                    child: const Text('Yarın sor'),
                  ),
                  FilledButton(
                    onPressed: onComplete,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF293C33),
                    ),
                    child: const Text('Tamamlandı'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ProposalPanel extends StatefulWidget {
  const _ProposalPanel({
    required this.proposals,
    required this.onApply,
    required this.onDismiss,
  });
  final List<ActionProposal> proposals;
  final Future<void> Function(List<FlowItem>) onApply;
  final VoidCallback onDismiss;

  @override
  State<_ProposalPanel> createState() => _ProposalPanelState();
}

class _ProposalPanelState extends State<_ProposalPanel> {
  late List<ActionProposal> _proposals;

  @override
  void initState() {
    super.initState();
    _proposals = widget.proposals;
  }

  Future<void> _editSchedule(int index) async {
    final current = _proposals[index].draft;
    final initial =
        current.scheduledAt ?? DateTime.now().add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: 'Hatırlatma tarihi',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: 'Hatırlatma saati',
    );
    if (time == null || !mounted) return;
    final scheduledAt = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    setState(() {
      _proposals[index] = _proposals[index].copyWith(
        draft: FlowItem(
          id: current.id,
          title: current.title,
          kind: current.kind,
          createdAt: current.createdAt,
          scheduledAt: scheduledAt,
          note: current.note,
          sourceText: current.sourceText,
          nextReviewAt: current.nextReviewAt,
          lastPromptedAt: current.lastPromptedAt,
          done: current.done,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: const Color(0xFFFFFCF6),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFFF0DFC0)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(
              Icons.auto_awesome_rounded,
              size: 18,
              color: Color(0xFFB57732),
            ),
            SizedBox(width: 8),
            Text(
              'Akış bunu hatırlasın mı?',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            Spacer(),
            Text(
              'İstersen düzenle',
              style: TextStyle(color: Color(0xFF8A7763), fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 15),
        ..._proposals.asMap().entries.map(
          (entry) => _MiniProposal(
            proposal: entry.value,
            onEditSchedule: () => _editSchedule(entry.key),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: widget.onDismiss,
              child: const Text('Vazgeç'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => widget.onApply(
                _proposals.map((proposal) => proposal.draft).toList(),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF293C33),
              ),
              child: const Text('Hafızaya al'),
            ),
          ],
        ),
      ],
    ),
  );
}

class _MiniProposal extends StatelessWidget {
  const _MiniProposal({required this.proposal, required this.onEditSchedule});
  final ActionProposal proposal;
  final VoidCallback onEditSchedule;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: proposal.draft.kind.tint,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            proposal.draft.kind.icon,
            size: 18,
            color: const Color(0xFF52645A),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                proposal.draft.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 3),
              Text(
                proposal.questions.isEmpty
                    ? 'Güven: %${(proposal.confidence * 100).round()}'
                    : proposal.questions.first,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: proposal.questions.isEmpty
                      ? const Color(0xFF6E8578)
                      : const Color(0xFFC06B32),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        TextButton.icon(
          onPressed: onEditSchedule,
          icon: const Icon(Icons.edit_calendar_rounded, size: 15),
          label: Text(_timeLabel(proposal.draft)),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF6654CE),
            textStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

class _TodayFlow extends StatelessWidget {
  const _TodayFlow({
    required this.items,
    required this.onToggle,
    required this.onDelete,
  });
  final List<FlowItem> items;
  final Future<void> Function(FlowItem) onToggle;
  final Future<void> Function(FlowItem) onDelete;
  @override
  Widget build(BuildContext context) {
    final visible = items.where((e) => !e.done).toList();
    final completed = items.where((e) => e.done).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Açık döngülerin',
                style: TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.7,
                ),
              ),
            ),
            Text(
              '${visible.length} bekleyen şey',
              style: TextStyle(color: Color(0xFF7D867F), fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 7),
        const Text(
          'Sözler, fikirler ve yarım kalanlar kaybolmasın.',
          style: TextStyle(color: Color(0xFF788179)),
        ),
        const SizedBox(height: 18),
        if (visible.isEmpty)
          const _EmptyState(label: 'Şimdilik aklında bekleyen bir şey yok.')
        else
          ...visible.map(
            (item) => _FlowCard(
              item: item,
              onTap: () => onToggle(item),
              onDelete: () => onDelete(item),
            ),
          ),
        if (completed.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF2F4F1),
              borderRadius: BorderRadius.circular(18),
            ),
            child: ExpansionTile(
              title: Text(
                'Tamamlananlar · ${completed.length}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: const Text(
                'İstersen geri açabilir ya da silebilirsin.',
              ),
              children: completed
                  .map(
                    (item) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: _FlowCard(
                        item: item,
                        onTap: () => onToggle(item),
                        onDelete: () => onDelete(item),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ],
    );
  }
}

class _FlowCard extends StatelessWidget {
  const _FlowCard({
    required this.item,
    required this.onTap,
    required this.onDelete,
  });
  final FlowItem item;
  final VoidCallback onTap;
  final Future<void> Function() onDelete;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(
      color: item.done ? const Color(0xFFF7F8F5) : Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFFE9ECE8)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              color: item.done ? const Color(0xFF355448) : Colors.transparent,
              border: Border.all(
                color: item.done
                    ? const Color(0xFF355448)
                    : const Color(0xFFC4CCC6),
                width: 1.5,
              ),
              borderRadius: BorderRadius.circular(9),
            ),
            child: item.done
                ? const Icon(Icons.check_rounded, size: 19, color: Colors.white)
                : null,
          ),
        ),
        const SizedBox(width: 14),
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: item.kind.tint,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(item.kind.icon, color: const Color(0xFF53655B)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: item.done ? const Color(0xFF7C867E) : null,
                  decoration: item.done ? TextDecoration.lineThrough : null,
                ),
              ),
              if (item.note != null) ...[
                const SizedBox(height: 4),
                Text(
                  item.note!,
                  style: const TextStyle(
                    color: Color(0xFF788179),
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    size: 14,
                    color: const Color(0xFF839088),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _timeLabel(item),
                    style: const TextStyle(
                      color: Color(0xFF6D7770),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Kart seçenekleri',
          icon: const Icon(Icons.more_horiz_rounded, color: Color(0xFF8B948E)),
          onSelected: (value) async {
            if (value == 'toggle') {
              onTap();
              return;
            }
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Kart silinsin mi?'),
                content: const Text('Bu işlem geri alınamaz.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Vazgeç'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFC34E48),
                    ),
                    child: const Text('Sil'),
                  ),
                ],
              ),
            );
            if (confirmed == true) await onDelete();
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'toggle',
              child: Text(
                item.done ? 'Tekrar aç' : 'Tamamlandı olarak işaretle',
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'delete',
              child: Text('Sil', style: TextStyle(color: Color(0xFFC34E48))),
            ),
          ],
        ),
      ],
    ),
  );
}

class _RightColumn extends StatelessWidget {
  const _RightColumn({required this.items});
  final List<FlowItem> items;
  @override
  Widget build(BuildContext context) {
    final open = items.where((item) => !item.done).length;
    final tomorrow = items
        .where(
          (item) =>
              item.scheduledAt != null &&
              item.scheduledAt!.difference(DateTime.now()).inDays == 0,
        )
        .length;
    final recentNotes = items
        .where((item) => item.kind == FlowKind.note)
        .take(3)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF3E2D83), Color(0xFF1C5F62)],
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              BoxShadow(
                color: Color(0x262B2671),
                blurRadius: 22,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                color: Color(0xFFF3D9A4),
                size: 25,
              ),
              const SizedBox(height: 24),
              Text(
                open == 0
                    ? 'Şimdilik açık döngün yok.'
                    : '$open şey aklında kalmasın diye burada.',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  height: 1.16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Bir söz, fikir ya da yarım kalanı bırak. Akış doğru zamanda geri getirir.',
                style: TextStyle(
                  color: Color(0xFFB8C7BD),
                  height: 1.4,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 26),
        const Text(
          'Hafızanın özeti',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _Stat(
                number: '$open',
                label: 'açık döngü',
                color: const Color(0xFFD8F7E7),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Stat(
                number: '$tomorrow',
                label: 'zamanı yakın',
                color: const Color(0xFFFBEAC9),
              ),
            ),
          ],
        ),
        if (recentNotes.isNotEmpty) ...[
          const SizedBox(height: 26),
          const Text(
            'Yakın zamanda saklananlar',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          ...recentNotes.map(
            (item) => _MemoryLine(
              icon: item.kind.icon,
              text: item.title,
              time: _timeLabel(item),
            ),
          ),
        ],
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.number, required this.label, required this.color});
  final String number;
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          number,
          style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(color: Color(0xFF68736C), fontSize: 12),
        ),
      ],
    ),
  );
}

class _MemoryLine extends StatelessWidget {
  const _MemoryLine({
    required this.icon,
    required this.text,
    required this.time,
  });
  final IconData icon;
  final String text;
  final String time;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: const Color(0xFFEFEFEA),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 17, color: const Color(0xFF5B6C62)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
        Text(
          time,
          style: const TextStyle(color: Color(0xFF8A938D), fontSize: 11),
        ),
      ],
    ),
  );
}

class _LogoMark extends StatelessWidget {
  const _LogoMark();
  @override
  Widget build(BuildContext context) => Container(
    width: 30,
    height: 30,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
    child: Image.asset(
      'assets/branding/akis_logo.png',
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
    ),
  );
}

class _MobileNav extends StatelessWidget {
  const _MobileNav({required this.selectedIndex, required this.onSelect});
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) => NavigationBar(
    selectedIndex: selectedIndex,
    onDestinationSelected: onSelect,
    destinations: const [
      NavigationDestination(icon: Icon(Icons.grid_view_rounded), label: 'Akış'),
      NavigationDestination(
        icon: Icon(Icons.check_circle_outline_rounded),
        label: 'Sözlerim',
      ),
      NavigationDestination(
        icon: Icon(Icons.calendar_month_outlined),
        label: 'Zamanı gelen',
      ),
      NavigationDestination(
        icon: Icon(Icons.sticky_note_2_outlined),
        label: 'Fikirler',
      ),
      NavigationDestination(
        icon: Icon(Icons.auto_awesome_outlined),
        label: 'Hafıza',
      ),
    ],
  );
}

String _timeLabel(FlowItem item) {
  final scheduledAt = item.scheduledAt;
  if (scheduledAt == null) return item.kind.label;
  final clock =
      '${scheduledAt.hour.toString().padLeft(2, '0')}:${scheduledAt.minute.toString().padLeft(2, '0')}';
  final today = DateTime.now();
  final tomorrow = today.add(const Duration(days: 1));
  if (scheduledAt.year == today.year &&
      scheduledAt.month == today.month &&
      scheduledAt.day == today.day) {
    return 'Bugün · $clock';
  }
  if (scheduledAt.year == tomorrow.year &&
      scheduledAt.month == tomorrow.month &&
      scheduledAt.day == tomorrow.day) {
    return 'Yarın · $clock';
  }
  return '${scheduledAt.day.toString().padLeft(2, '0')}.${scheduledAt.month.toString().padLeft(2, '0')} · $clock';
}

String _reviewLabel(DateTime value) {
  final now = DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  final target = DateTime(value.year, value.month, value.day);
  final days = target.difference(day).inDays;
  if (days == 0) return 'Bugün';
  if (days == 1) return 'Yarın';
  return '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}';
}

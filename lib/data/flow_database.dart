import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../models/flow_item.dart';

class FlowDatabase {
  FlowDatabase._();

  static final instance = FlowDatabase._();
  Database? _database;

  Future<void> open({bool inMemory = false}) async {
    if (_database != null) return;
    final Database database;
    if (inMemory) {
      database = sqlite3.openInMemory();
    } else {
      final directory = await getApplicationSupportDirectory();
      final file = File(path.join(directory.path, 'akis.sqlite'));
      database = sqlite3.open(file.path);
    }
    database.execute('''
      CREATE TABLE IF NOT EXISTS flow_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        kind TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        scheduled_at INTEGER,
        note TEXT,
        source_text TEXT,
        next_review_at INTEGER,
        last_prompted_at INTEGER,
        is_done INTEGER NOT NULL DEFAULT 0
      )
    ''');
    _migrate(database);
    _database = database;
  }

  /// Adds columns instead of replacing the table, so early users keep all of
  /// their existing cards as Akış grows.
  void _migrate(Database database) {
    final columns = database
        .select('PRAGMA table_info(flow_items)')
        .map((row) => row['name'] as String)
        .toSet();
    database.execute('BEGIN TRANSACTION');
    try {
      if (!columns.contains('source_text')) {
        database.execute('ALTER TABLE flow_items ADD COLUMN source_text TEXT');
      }
      if (!columns.contains('next_review_at')) {
        database.execute(
          'ALTER TABLE flow_items ADD COLUMN next_review_at INTEGER',
        );
      }
      if (!columns.contains('last_prompted_at')) {
        database.execute(
          'ALTER TABLE flow_items ADD COLUMN last_prompted_at INTEGER',
        );
      }
      database.execute('PRAGMA user_version = 2');
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  Database get _db {
    final database = _database;
    if (database == null) throw StateError('Veritabanı henüz açılmadı.');
    return database;
  }

  Future<List<FlowItem>> readItems({FlowKind? kind}) async {
    final query = StringBuffer('SELECT * FROM flow_items');
    final parameters = <Object?>[];
    if (kind != null) {
      query.write(' WHERE kind = ?');
      parameters.add(kind.name);
    }
    query.write(
      ' ORDER BY is_done ASC, COALESCE(next_review_at, created_at) ASC, created_at DESC',
    );
    return _db.select(query.toString(), parameters).map(_fromRow).toList();
  }

  Future<FlowItem> insert(FlowItem item) async {
    return _insert(item);
  }

  /// Persists a group of approved cards as one local change. A partial spoken
  /// instruction must never leave only its first few cards in the database.
  Future<List<FlowItem>> insertAll(Iterable<FlowItem> items) async {
    final drafts = items.toList(growable: false);
    if (drafts.isEmpty) return const [];
    _db.execute('BEGIN TRANSACTION');
    try {
      final saved = drafts.map(_insert).toList(growable: false);
      _db.execute('COMMIT');
      return saved;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  FlowItem _insert(FlowItem item) {
    _db.execute(
      '''INSERT INTO flow_items
        (title, kind, created_at, scheduled_at, note, source_text,
         next_review_at, last_prompted_at, is_done)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        item.title,
        item.kind.name,
        item.createdAt.millisecondsSinceEpoch,
        item.scheduledAt?.millisecondsSinceEpoch,
        item.note,
        item.sourceText,
        item.nextReviewAt?.millisecondsSinceEpoch,
        item.lastPromptedAt?.millisecondsSinceEpoch,
        item.done ? 1 : 0,
      ],
    );
    final id = _db.lastInsertRowId;
    return FlowItem(
      id: id,
      title: item.title,
      kind: item.kind,
      createdAt: item.createdAt,
      scheduledAt: item.scheduledAt,
      note: item.note,
      sourceText: item.sourceText,
      nextReviewAt: item.nextReviewAt,
      lastPromptedAt: item.lastPromptedAt,
      done: item.done,
    );
  }

  Future<List<FlowItem>> readDueReviews({DateTime? now}) async {
    final reference = now ?? DateTime.now();
    return _db
        .select(
          '''SELECT * FROM flow_items
            WHERE is_done = 0
              AND next_review_at IS NOT NULL
              AND next_review_at <= ?
            ORDER BY next_review_at ASC''',
          [reference.millisecondsSinceEpoch],
        )
        .map(_fromRow)
        .toList();
  }

  Future<void> deferReview(int id, DateTime until) async {
    _db.execute(
      '''UPDATE flow_items
        SET next_review_at = ?, last_prompted_at = ?
        WHERE id = ?''',
      [until.millisecondsSinceEpoch, DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  Future<void> setDone(int id, bool done) async {
    _db.execute('UPDATE flow_items SET is_done = ? WHERE id = ?', [
      done ? 1 : 0,
      id,
    ]);
  }

  Future<void> delete(int id) async {
    _db.execute('DELETE FROM flow_items WHERE id = ?', [id]);
  }

  Future<void> clear() async {
    _db.execute('DELETE FROM flow_items');
  }

  FlowItem _fromRow(Row row) => FlowItem(
    id: row['id'] as int,
    title: row['title'] as String,
    kind: FlowKind.values.byName(row['kind'] as String),
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    scheduledAt: row['scheduled_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['scheduled_at'] as int),
    note: row['note'] as String?,
    sourceText: row['source_text'] as String?,
    nextReviewAt: row['next_review_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['next_review_at'] as int),
    lastPromptedAt: row['last_prompted_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['last_prompted_at'] as int),
    done: (row['is_done'] as int) == 1,
  );
}

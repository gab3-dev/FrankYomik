import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/study_document.dart';

/// Local PDF library, reading position, and downloaded OCR page layouts.
/// Kept separate from CacheService, whose schema is for translated images.
class StudyLibraryService {
  static const maxPdfBytes = 100 * 1024 * 1024;

  static Future<StudyLibraryService>? _opening;
  late final Database _db;
  late final Directory _root;

  StudyLibraryService._();

  Directory get studyDirectory => _root;

  static Future<StudyLibraryService> open({Directory? rootOverride}) {
    if (rootOverride != null) return _create(rootOverride: rootOverride);
    return _opening ??= _create();
  }

  static Future<StudyLibraryService> _create({Directory? rootOverride}) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final service = StudyLibraryService._();
    if (rootOverride != null) {
      service._root = rootOverride;
    } else {
      final Directory appDirectory;
      if (Platform.isLinux) {
        final docs = await getApplicationDocumentsDirectory();
        appDirectory = Directory(p.join(docs.path, '.frank_client'));
      } else {
        appDirectory = await getApplicationSupportDirectory();
      }
      service._root = Directory(p.join(appDirectory.path, 'study'));
    }
    await Directory(p.join(service._root.path, 'pdfs')).create(recursive: true);
    await Directory(
      p.join(service._root.path, 'dictionary'),
    ).create(recursive: true);

    service._db = await openDatabase(
      p.join(service._root.path, 'study_library.db'),
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE documents (
            document_id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            path TEXT NOT NULL,
            page_number INTEGER NOT NULL DEFAULT 1,
            page_count INTEGER,
            server_document_id TEXT,
            added_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE page_layouts (
            document_id TEXT NOT NULL,
            page_number INTEGER NOT NULL,
            layout_json TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (document_id, page_number)
          )
        ''');
        await _createMlKitCropsTable(db);
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) await _createMlKitCropsTable(db);
      },
    );
    return service;
  }

  Future<List<StudyDocument>> listDocuments() async {
    final rows = await _db.query('documents', orderBy: 'added_at DESC');
    return rows.map(StudyDocument.fromRow).toList(growable: false);
  }

  Future<StudyDocument?> getDocument(String id) async {
    final rows = await _db.query(
      'documents',
      where: 'document_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : StudyDocument.fromRow(rows.first);
  }

  /// Copies the picked PDF into app-owned storage so it remains available after
  /// the platform picker releases its temporary URI/cache file.
  Future<StudyDocument> importPdf({
    required String sourcePath,
    required String title,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const FileSystemException('PDF file not found');
    }
    final length = await source.length();
    if (length < 5 || length > maxPdfBytes) {
      throw const FormatException('PDF must be between 5 bytes and 100 MiB');
    }
    final signature = await source
        .openRead(0, 5)
        .fold<List<int>>([], (a, b) => a..addAll(b));
    if (ascii.decode(signature, allowInvalid: true) != '%PDF-') {
      throw const FormatException('The selected file is not a PDF');
    }

    final digest = await sha256.bind(source.openRead()).first;
    final id = digest.toString();
    final existing = await getDocument(id);
    if (existing != null && await File(existing.path).exists()) return existing;

    final localFile = File(p.join(_root.path, 'pdfs', '$id.pdf'));
    if (source.absolute.path != localFile.absolute.path) {
      await source.copy(localFile.path);
    }
    final document = StudyDocument(
      id: id,
      title: p.basenameWithoutExtension(title).trim().isEmpty
          ? 'Japanese PDF'
          : p.basenameWithoutExtension(title),
      path: localFile.path,
      pageNumber: 1,
      pageCount: null,
      serverDocumentId: null,
      addedAt: DateTime.now(),
    );
    await _db.insert(
      'documents',
      _documentValues(document),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return document;
  }

  Future<void> updateProgress(
    StudyDocument document, {
    required int pageNumber,
    int? pageCount,
  }) async {
    final values = <String, Object?>{'page_number': pageNumber};
    if (pageCount != null) values['page_count'] = pageCount;
    await _db.update(
      'documents',
      values,
      where: 'document_id = ?',
      whereArgs: [document.id],
    );
  }

  Future<void> setServerDocumentId(String localId, String? serverId) async {
    await _db.update(
      'documents',
      {'server_document_id': serverId},
      where: 'document_id = ?',
      whereArgs: [localId],
    );
  }

  Future<Map<String, dynamic>?> getPageLayout(
    String documentId,
    int page,
  ) async {
    final rows = await _db.query(
      'page_layouts',
      columns: ['layout_json'],
      where: 'document_id = ? AND page_number = ?',
      whereArgs: [documentId, page],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['layout_json']! as String)
        as Map<String, dynamic>;
  }

  Future<void> savePageLayout(
    String documentId,
    int page,
    Map<String, dynamic> layout,
  ) async {
    await _db.insert('page_layouts', {
      'document_id': documentId,
      'page_number': page,
      'layout_json': jsonEncode(layout),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<StudyMlKitCrop>> getMlKitCrops(
    String documentId,
    int page,
  ) async {
    final rows = await _db.query(
      'mlkit_crops',
      where: 'document_id = ? AND page_number = ?',
      whereArgs: [documentId, page],
      orderBy: 'created_at ASC',
    );
    return rows.map(StudyMlKitCrop.fromRow).toList(growable: false);
  }

  Future<void> saveMlKitCrop(StudyMlKitCrop crop) => _db.insert(
    'mlkit_crops',
    crop.toRow(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<void> removeDocument(StudyDocument document) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'page_layouts',
        where: 'document_id = ?',
        whereArgs: [document.id],
      );
      await txn.delete(
        'mlkit_crops',
        where: 'document_id = ?',
        whereArgs: [document.id],
      );
      await txn.delete(
        'documents',
        where: 'document_id = ?',
        whereArgs: [document.id],
      );
    });
    try {
      await File(document.path).delete();
    } on FileSystemException catch (e) {
      debugPrint('[Study] Could not remove local PDF ${document.path}: $e');
    }
  }

  Map<String, Object?> _documentValues(StudyDocument document) => {
    'document_id': document.id,
    'title': document.title,
    'path': document.path,
    'page_number': document.pageNumber,
    'page_count': document.pageCount,
    'server_document_id': document.serverDocumentId,
    'added_at': document.addedAt.millisecondsSinceEpoch,
  };

  static Future<void> _createMlKitCropsTable(DatabaseExecutor db) =>
      db.execute('''
    CREATE TABLE IF NOT EXISTS mlkit_crops (
      crop_id INTEGER PRIMARY KEY,
      document_id TEXT NOT NULL,
      page_number INTEGER NOT NULL,
      left_fraction REAL NOT NULL,
      top_fraction REAL NOT NULL,
      right_fraction REAL NOT NULL,
      bottom_fraction REAL NOT NULL,
      text TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');

  Future<void> close() => _db.close();
}

class StudyMlKitCrop {
  final int id;
  final String documentId;
  final int pageNumber;
  final double left;
  final double top;
  final double right;
  final double bottom;
  final String text;
  final DateTime createdAt;

  const StudyMlKitCrop({
    required this.id,
    required this.documentId,
    required this.pageNumber,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.text,
    required this.createdAt,
  });

  factory StudyMlKitCrop.fromRow(Map<String, Object?> row) => StudyMlKitCrop(
    id: row['crop_id']! as int,
    documentId: row['document_id']! as String,
    pageNumber: row['page_number']! as int,
    left: (row['left_fraction']! as num).toDouble(),
    top: (row['top_fraction']! as num).toDouble(),
    right: (row['right_fraction']! as num).toDouble(),
    bottom: (row['bottom_fraction']! as num).toDouble(),
    text: row['text']! as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int),
  );

  Map<String, Object?> toRow() => {
    'crop_id': id,
    'document_id': documentId,
    'page_number': pageNumber,
    'left_fraction': left,
    'top_fraction': top,
    'right_fraction': right,
    'bottom_fraction': bottom,
    'text': text,
    'created_at': createdAt.millisecondsSinceEpoch,
  };
}

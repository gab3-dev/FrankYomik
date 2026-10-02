import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class JapaneseWordMatch {
  final String form;
  final bool common;
  final List<String> readings;
  final List<Map<String, dynamic>> senses;

  const JapaneseWordMatch({
    required this.form,
    required this.common,
    required this.readings,
    required this.senses,
  });
}

class JapaneseKanjiEntry {
  final String literal;
  final List<String> readings;
  final List<String> meanings;

  const JapaneseKanjiEntry({
    required this.literal,
    required this.readings,
    required this.meanings,
  });
}

class JapaneseLookupResult {
  final int characterIndex;
  final String character;
  final List<JapaneseWordMatch> words;
  final JapaneseKanjiEntry? kanji;
  final String? surfaceHint;
  final String? readingHint;
  final List<String> partOfSpeechHint;

  const JapaneseLookupResult({
    required this.characterIndex,
    required this.character,
    required this.words,
    required this.kanji,
    this.surfaceHint,
    this.readingHint,
    this.partOfSpeechHint = const [],
  });
}

/// On-device JMdict/KANJIDIC2 index. Definitions are downloaded once from the
/// jmdict-simplified release archive, indexed in SQLite, and then queried
/// locally for every tap. The source data remains subject to its upstream
/// licenses; the UI exposes attribution beside the install/update control.
class LocalJapaneseDictionary {
  static const attribution =
      'JMdict © Electronic Dictionary Research and Development Group (EDRDG), '
      'used under the EDRDG license. KANJIDIC2 © EDRDG, CC BY-SA 4.0. '
      'Data format/source: github.com/scriptin/jmdict-simplified.';
  static const _releaseApi =
      'https://api.github.com/repos/scriptin/jmdict-simplified/releases/latest';

  final Database _db;
  final http.Client _client;
  bool _installing = false;

  LocalJapaneseDictionary._(this._db, this._client);

  static Future<LocalJapaneseDictionary> open(
    Directory studyDirectory, {
    http.Client? client,
  }) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = Directory(p.join(studyDirectory.path, 'dictionary'));
    await dir.create(recursive: true);
    final db = await openDatabase(
      p.join(dir.path, 'japanese_dictionary.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE dictionary_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE words (
            entry_id TEXT PRIMARY KEY,
            payload TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE word_forms (
            form TEXT NOT NULL,
            entry_id TEXT NOT NULL,
            common INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (form, entry_id)
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_word_forms_form ON word_forms(form)',
        );
        await db.execute('''
          CREATE TABLE kanji (
            literal TEXT PRIMARY KEY,
            payload TEXT NOT NULL
          )
        ''');
      },
    );
    return LocalJapaneseDictionary._(db, client ?? http.Client());
  }

  Future<bool> get isInstalled async {
    final rows = await _db.query(
      'dictionary_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['ready'],
      limit: 1,
    );
    return rows.isNotEmpty && rows.first['value'] == '1';
  }

  Future<String?> get installedVersion async {
    final rows = await _db.query(
      'dictionary_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['source_version'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  /// Downloads the latest English common-word JMdict and English KANJIDIC2
  /// archives and installs a local lookup index.
  Future<void> installOrUpdate({
    void Function(double progress)? onProgress,
  }) async {
    if (_installing) {
      throw StateError('Dictionary installation is already running');
    }
    _installing = true;
    try {
      final releaseResponse = await _client
          .get(
            Uri.parse(_releaseApi),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'Frank-Yomik',
            },
          )
          .timeout(const Duration(seconds: 30));
      if (releaseResponse.statusCode != 200) {
        throw HttpException(
          'Dictionary release lookup failed (${releaseResponse.statusCode})',
        );
      }
      final release = jsonDecode(releaseResponse.body) as Map<String, dynamic>;
      final version = release['tag_name'] as String? ?? 'unknown';
      final assets = (release['assets'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      final wordAsset = _findAsset(assets, 'jmdict-eng-common-');
      final kanjiAsset = _findAsset(assets, 'kanjidic2-en-');

      onProgress?.call(0.05);
      final wordData = await _downloadJsonZip(wordAsset);
      onProgress?.call(0.48);
      final kanjiData = await _downloadJsonZip(kanjiAsset);
      onProgress?.call(0.88);
      await _replaceIndex(wordData, kanjiData, version);
      onProgress?.call(1.0);
    } finally {
      _installing = false;
    }
  }

  /// Install already-downloaded dictionary JSON, also used by local mirrors
  /// and deterministic tests without a network request.
  Future<void> installFromJsonData({
    required Map<String, dynamic> words,
    required Map<String, dynamic> kanji,
    required String version,
  }) => _replaceIndex(words, kanji, version);

  Future<Map<String, dynamic>> _downloadJsonZip(
    Map<String, dynamic> asset,
  ) async {
    final url = asset['browser_download_url'] as String?;
    if (url == null) {
      throw const FormatException('Dictionary archive URL is missing');
    }
    final response = await _client
        .get(Uri.parse(url))
        .timeout(const Duration(minutes: 2));
    if (response.statusCode != 200) {
      throw HttpException(
        'Dictionary download failed (${response.statusCode})',
      );
    }
    final archive = ZipDecoder().decodeBytes(response.bodyBytes);
    ArchiveFile? file;
    for (final candidate in archive.files) {
      if (candidate.isFile && candidate.name.toLowerCase().endsWith('.json')) {
        file = candidate;
        break;
      }
    }
    if (file == null) {
      throw const FormatException('Dictionary archive has no JSON file');
    }
    final content = file.content;
    final decoded = jsonDecode(utf8.decode(content));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Dictionary JSON root must be an object');
    }
    return decoded;
  }

  Map<String, dynamic> _findAsset(
    List<Map<String, dynamic>> assets,
    String prefix,
  ) {
    for (final asset in assets) {
      final name = asset['name'] as String? ?? '';
      if (name.startsWith(prefix) && name.endsWith('.json.zip')) return asset;
    }
    throw FormatException('No $prefix dictionary archive in release');
  }

  Future<void> _replaceIndex(
    Map<String, dynamic> wordsData,
    Map<String, dynamic> kanjiData,
    String version,
  ) async {
    final words = wordsData['words'];
    final characters = kanjiData['characters'];
    if (words is! List || characters is! List) {
      throw const FormatException(
        'Dictionary JSON does not contain expected entries',
      );
    }

    await _db.transaction((txn) async {
      await txn.delete('word_forms');
      await txn.delete('words');
      await txn.delete('kanji');
      await txn.delete('dictionary_meta');

      var batch = txn.batch();
      var pending = 0;
      Future<void> flush() async {
        if (pending == 0) return;
        await batch.commit(noResult: true);
        batch = txn.batch();
        pending = 0;
      }

      for (final raw in words) {
        if (raw is! Map<String, dynamic>) continue;
        final id = raw['id']?.toString();
        if (id == null || id.isEmpty) continue;
        final writings = _maps(raw['kanji']);
        final readings = _maps(raw['kana']);
        final senses = _maps(raw['sense']);
        final englishSenses = <Map<String, dynamic>>[];
        for (final sense in senses) {
          final glosses = _maps(sense['gloss'])
              .where((gloss) => gloss['lang'] == 'eng')
              .map((gloss) => gloss['text'].toString())
              .toList(growable: false);
          if (glosses.isNotEmpty) {
            englishSenses.add({
              'part_of_speech':
                  (sense['partOfSpeech'] as List<dynamic>? ?? const [])
                      .map((tag) => tag.toString())
                      .toList(growable: false),
              'glosses': glosses,
            });
          }
        }
        final payload = {
          'id': id,
          'readings': readings.map((r) => r['text'].toString()).toList(),
          'senses': englishSenses,
        };
        batch.insert('words', {
          'entry_id': id,
          'payload': jsonEncode(payload),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        for (final writing in [...writings, ...readings]) {
          final form = writing['text']?.toString();
          if (form == null || form.isEmpty) continue;
          batch.insert('word_forms', {
            'form': form,
            'entry_id': id,
            'common': writing['common'] == true ? 1 : 0,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        pending += 1 + writings.length + readings.length;
        if (pending >= 900) await flush();
      }
      await flush();

      batch = txn.batch();
      pending = 0;
      for (final raw in characters) {
        if (raw is! Map<String, dynamic>) continue;
        final literal = raw['literal']?.toString();
        if (literal == null || literal.isEmpty) continue;
        final readingMeaning = raw['readingMeaning'];
        final groups = readingMeaning is Map<String, dynamic>
            ? _maps(readingMeaning['groups'])
            : const <Map<String, dynamic>>[];
        final readings = <String>[];
        final meanings = <String>[];
        for (final group in groups) {
          for (final reading in _maps(group['readings'])) {
            final kind = reading['type'];
            if (kind == 'ja_on' || kind == 'ja_kun') {
              readings.add(reading['value'].toString());
            }
          }
          for (final meaning in _maps(group['meanings'])) {
            if (meaning['lang'] == 'en') {
              meanings.add(meaning['value'].toString());
            }
          }
        }
        batch.insert('kanji', {
          'literal': literal,
          'payload': jsonEncode({
            'literal': literal,
            'readings': readings.toSet().toList(),
            'meanings': meanings.toSet().toList(),
          }),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        pending++;
        if (pending >= 900) await flush();
      }
      await flush();
      await txn.insert('dictionary_meta', {
        'key': 'source_version',
        'value': version,
      });
      await txn.insert('dictionary_meta', {'key': 'ready', 'value': '1'});
    });
  }

  Future<JapaneseLookupResult> lookupAt({
    required String text,
    required int characterIndex,
    String? preferredForm,
    String? surfaceHint,
    String? readingHint,
    List<String> partOfSpeechHint = const [],
  }) async {
    if (!await isInstalled) {
      throw StateError('Local dictionary is not installed');
    }
    if (characterIndex < 0 || characterIndex >= text.length) {
      throw RangeError.index(characterIndex, text, 'characterIndex');
    }
    final runes = text.runes.toList(growable: false);
    final runeIndex = _runeIndexForCodeUnit(text, characterIndex);
    if (runeIndex < 0 || runeIndex >= runes.length) {
      throw RangeError.index(characterIndex, text, 'characterIndex');
    }
    final character = String.fromCharCode(runes[runeIndex]);
    final forms = _candidateForms(runes, runeIndex);
    final words = <JapaneseWordMatch>[];
    var rows = <Map<String, Object?>>[];
    if (preferredForm != null && preferredForm.isNotEmpty) {
      rows = await _queryForms({preferredForm});
    }
    if (rows.isEmpty && forms.isNotEmpty) {
      rows = await _queryForms(forms);
    }
    if (rows.isNotEmpty) {
      var bestLength = 0;
      final seen = <String>{};
      for (final row in rows) {
        final form = row['form']! as String;
        final formLength = form.runes.length;
        if (bestLength == 0) bestLength = formLength;
        if (formLength < bestLength) break;
        final payload =
            jsonDecode(row['payload']! as String) as Map<String, dynamic>;
        final id = payload['id']?.toString() ?? form;
        if (!seen.add(id)) continue;
        words.add(
          JapaneseWordMatch(
            form: form,
            common: row['common'] == 1,
            readings: (payload['readings'] as List<dynamic>? ?? const [])
                .map((value) => value.toString())
                .toList(growable: false),
            senses: (payload['senses'] as List<dynamic>? ?? const [])
                .whereType<Map<String, dynamic>>()
                .toList(growable: false),
          ),
        );
      }
    }

    JapaneseKanjiEntry? kanji;
    if (_isKanji(character)) {
      final rows = await _db.query(
        'kanji',
        columns: ['payload'],
        where: 'literal = ?',
        whereArgs: [character],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final payload =
            jsonDecode(rows.first['payload']! as String)
                as Map<String, dynamic>;
        kanji = JapaneseKanjiEntry(
          literal: character,
          readings: (payload['readings'] as List<dynamic>? ?? const [])
              .map((value) => value.toString())
              .toList(growable: false),
          meanings: (payload['meanings'] as List<dynamic>? ?? const [])
              .map((value) => value.toString())
              .toList(growable: false),
        );
      }
    }
    return JapaneseLookupResult(
      characterIndex: characterIndex,
      character: character,
      words: words,
      kanji: kanji,
      surfaceHint: surfaceHint,
      readingHint: readingHint,
      partOfSpeechHint: partOfSpeechHint,
    );
  }

  Future<List<Map<String, Object?>>> _queryForms(Set<String> forms) async {
    if (forms.isEmpty) return [];
    final marks = List.filled(forms.length, '?').join(',');
    return _db.rawQuery('''
      SELECT word_forms.form, word_forms.common, words.payload
      FROM word_forms JOIN words ON words.entry_id = word_forms.entry_id
      WHERE word_forms.form IN ($marks)
      ORDER BY length(word_forms.form) DESC, word_forms.common DESC
      LIMIT 12
    ''', forms.toList(growable: false));
  }

  Set<String> _candidateForms(List<int> runes, int index) {
    const maxRunes = 12;
    final startLimit = (index - maxRunes + 1).clamp(0, index).toInt();
    final endLimit = (index + maxRunes).clamp(index + 1, runes.length).toInt();
    final forms = <String>{};
    for (var start = startLimit; start <= index; start++) {
      if (!_isWordCodePoint(runes[start])) continue;
      for (var end = index + 1; end <= endLimit; end++) {
        if (!_isWordCodePoint(runes[end - 1])) break;
        final candidate = String.fromCharCodes(runes.sublist(start, end));
        forms.add(candidate);
      }
    }
    return forms;
  }

  int _runeIndexForCodeUnit(String text, int codeUnitIndex) {
    var codeUnitOffset = 0;
    var runeIndex = 0;
    for (final rune in text.runes) {
      final codeUnits = String.fromCharCode(rune).length;
      if (codeUnitIndex < codeUnitOffset + codeUnits) return runeIndex;
      codeUnitOffset += codeUnits;
      runeIndex++;
    }
    return -1;
  }

  bool _isWordCodePoint(int value) =>
      (value >= 0x3040 && value <= 0x30ff) ||
      (value >= 0x3400 && value <= 0x4dbf) ||
      (value >= 0x4e00 && value <= 0x9fff) ||
      (value >= 0xf900 && value <= 0xfaff) ||
      (value >= 0x20000 && value <= 0x323af) ||
      (value >= 0xff10 && value <= 0xff19) ||
      (value >= 0x30 && value <= 0x39) ||
      (value >= 0x41 && value <= 0x5a) ||
      (value >= 0x61 && value <= 0x7a);

  bool _isKanji(String value) {
    if (value.isEmpty) return false;
    final rune = value.runes.first;
    return (rune >= 0x3400 && rune <= 0x4dbf) ||
        (rune >= 0x4e00 && rune <= 0x9fff) ||
        (rune >= 0xf900 && rune <= 0xfaff) ||
        (rune >= 0x20000 && rune <= 0x323af);
  }

  List<Map<String, dynamic>> _maps(Object? value) =>
      (value as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);

  Future<void> close() async {
    _client.close();
    await _db.close();
  }
}

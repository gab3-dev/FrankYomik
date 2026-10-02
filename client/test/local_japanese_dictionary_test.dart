import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frank_client/services/local_japanese_dictionary.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'release archives install a local word and kanji lookup index',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'frank-dictionary-test-',
      );
      addTearDown(() => root.delete(recursive: true));

      final wordsArchive = _zipJson({
        'words': [
          {
            'id': '1',
            'kanji': [
              {'text': '日本語', 'common': true},
            ],
            'kana': [
              {'text': 'にほんご', 'common': true},
            ],
            'sense': [
              {
                'partOfSpeech': ['n'],
                'gloss': [
                  {'lang': 'eng', 'text': 'Japanese language'},
                ],
              },
            ],
          },
          {
            'id': '2',
            'kanji': [
              {'text': '𠮷日', 'common': true},
            ],
            'kana': [
              {'text': 'よしひ', 'common': true},
            ],
            'sense': [
              {
                'partOfSpeech': ['n'],
                'gloss': [
                  {'lang': 'eng', 'text': 'fixture name'},
                ],
              },
            ],
          },
          {
            'id': '3',
            'kanji': [
              {'text': '食べる', 'common': true},
            ],
            'kana': [
              {'text': 'たべる', 'common': true},
            ],
            'sense': [
              {
                'partOfSpeech': ['v1'],
                'gloss': [
                  {'lang': 'eng', 'text': 'to eat'},
                ],
              },
            ],
          },
        ],
      });
      final kanjiArchive = _zipJson({
        'characters': [
          {
            'literal': '日',
            'readingMeaning': {
              'groups': [
                {
                  'readings': [
                    {'type': 'ja_on', 'value': 'ニチ'},
                  ],
                  'meanings': [
                    {'lang': 'en', 'value': 'day; sun'},
                  ],
                },
              ],
            },
          },
          {
            'literal': '𠮷',
            'readingMeaning': {
              'groups': [
                {
                  'readings': [
                    {'type': 'ja_kun', 'value': 'よし'},
                  ],
                  'meanings': [
                    {'lang': 'en', 'value': 'good fortune'},
                  ],
                },
              ],
            },
          },
        ],
      });
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return http.Response(
            jsonEncode({
              'tag_name': 'fixture-1',
              'assets': [
                {
                  'name': 'jmdict-eng-common-fixture.json.zip',
                  'browser_download_url': 'https://fixture/words.zip',
                },
                {
                  'name': 'kanjidic2-en-fixture.json.zip',
                  'browser_download_url': 'https://fixture/kanji.zip',
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/words.zip') {
          return http.Response.bytes(wordsArchive, 200);
        }
        if (request.url.path == '/kanji.zip') {
          return http.Response.bytes(kanjiArchive, 200);
        }
        return http.Response('unexpected request: ${request.url}', 404);
      });
      final dictionary = await LocalJapaneseDictionary.open(
        root,
        client: client,
      );
      addTearDown(dictionary.close);

      await dictionary.installOrUpdate();
      expect(await dictionary.isInstalled, isTrue);
      expect(await dictionary.installedVersion, 'fixture-1');

      final result = await dictionary.lookupAt(
        text: '日本語を読む',
        characterIndex: 0,
      );
      expect(result.character, '日');
      expect(result.words, hasLength(1));
      expect(result.words.single.form, '日本語');
      expect(result.words.single.readings, contains('にほんご'));
      expect(
        result.words.single.senses.single['glosses'],
        contains('Japanese language'),
      );
      expect(result.kanji?.meanings, contains('day; sun'));

      final supplementary = await dictionary.lookupAt(
        text: '𠮷日',
        characterIndex: 0,
      );
      expect(supplementary.character, '𠮷');
      expect(supplementary.words.single.form, '𠮷日');
      expect(supplementary.kanji?.meanings, contains('good fortune'));

      final conjugated = await dictionary.lookupAt(
        text: '食べました',
        characterIndex: 0,
        preferredForm: '食べる',
        surfaceHint: '食べました',
        readingHint: 'タベマシタ',
      );
      expect(conjugated.words.single.form, '食べる');
      expect(conjugated.surfaceHint, '食べました');
    },
  );
}

Uint8List _zipJson(Map<String, dynamic> json) {
  final archive = Archive()
    ..addFile(ArchiveFile.string('dictionary.json', jsonEncode(json)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

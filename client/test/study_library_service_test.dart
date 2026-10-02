import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frank_client/services/study_library_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'imports PDF locally, deduplicates by content, and stores page layouts',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'frank-study-library-test-',
      );
      final source = File('${root.path}/picked.pdf')
        ..writeAsBytesSync(utf8.encode('%PDF-1.7\nfixture'));
      final library = await StudyLibraryService.open(
        rootOverride: Directory('${root.path}/study'),
      );
      addTearDown(() async {
        await library.close();
        await root.delete(recursive: true);
      });

      final imported = await library.importPdf(
        sourcePath: source.path,
        title: 'study-book.pdf',
      );
      expect(await File(imported.path).exists(), isTrue);
      expect(imported.title, 'study-book');

      final duplicate = await library.importPdf(
        sourcePath: source.path,
        title: 'another-name.pdf',
      );
      expect(duplicate.id, imported.id);
      expect((await library.listDocuments()).length, 1);

      await library.updateProgress(imported, pageNumber: 4, pageCount: 20);
      await library.setServerDocumentId(imported.id, 'temporary-server-id');
      final layout = {'page_number': 4, 'text': '日本語', 'glyphs': []};
      await library.savePageLayout(imported.id, 4, layout);

      final saved = (await library.listDocuments()).single;
      expect(saved.pageNumber, 4);
      expect(saved.pageCount, 20);
      expect(saved.serverDocumentId, 'temporary-server-id');
      expect(await library.getPageLayout(imported.id, 4), layout);
    },
  );

  test('rejects files without a PDF signature', () async {
    final root = await Directory.systemTemp.createTemp(
      'frank-study-invalid-test-',
    );
    final source = File('${root.path}/not.pdf')..writeAsStringSync('not a PDF');
    final library = await StudyLibraryService.open(
      rootOverride: Directory('${root.path}/study'),
    );
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });

    await expectLater(
      library.importPdf(sourcePath: source.path, title: 'not.pdf'),
      throwsFormatException,
    );
  });

  test('stores ML Kit crop transcripts with their page coordinates', () async {
    final root = await Directory.systemTemp.createTemp(
      'frank-study-crop-test-',
    );
    final library = await StudyLibraryService.open(rootOverride: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final crop = StudyMlKitCrop(
      id: 1,
      documentId: 'document',
      pageNumber: 3,
      left: 0.1,
      top: 0.2,
      right: 0.6,
      bottom: 0.7,
      text: '日本語',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
    );

    await library.saveMlKitCrop(crop);

    final saved = await library.getMlKitCrops('document', 3);
    expect(saved, hasLength(1));
    expect(saved.single.text, '日本語');
    expect(saved.single.left, 0.1);
    expect(saved.single.bottom, 0.7);
    expect(await library.getMlKitCrops('document', 4), isEmpty);
  });
}

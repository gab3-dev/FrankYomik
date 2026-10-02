import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/study_document.dart';
import '../services/local_japanese_dictionary.dart';
import '../services/study_library_service.dart';
import 'study_reader_screen.dart';

class StudyLibraryScreen extends ConsumerStatefulWidget {
  const StudyLibraryScreen({super.key});

  @override
  ConsumerState<StudyLibraryScreen> createState() => _StudyLibraryScreenState();
}

class _StudyLibraryScreenState extends ConsumerState<StudyLibraryScreen> {
  late final Future<StudyLibraryService> _libraryFuture;
  bool _importing = false;
  bool _installingDictionary = false;
  double _dictionaryProgress = 0;
  String? _message;

  @override
  void initState() {
    super.initState();
    _libraryFuture = StudyLibraryService.open();
  }

  Future<void> _importPdf() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      allowMultiple: false,
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.single;
    if (file.path == null) {
      setState(() => _message = 'Could not access the selected PDF.');
      return;
    }

    setState(() {
      _importing = true;
      _message = null;
    });
    try {
      final library = await _libraryFuture;
      final document = await library.importPdf(
        sourcePath: file.path!,
        title: file.name,
      );
      if (!mounted) return;
      await _openDocument(document);
    } on Object catch (error) {
      if (mounted) setState(() => _message = 'Could not import PDF: $error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _openDocument(StudyDocument document) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => StudyReaderScreen(document: document),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _installDictionary(StudyLibraryService library) async {
    LocalJapaneseDictionary? dictionary;
    setState(() {
      _installingDictionary = true;
      _dictionaryProgress = 0;
      _message = null;
    });
    try {
      dictionary = await LocalJapaneseDictionary.open(library.studyDirectory);
      await dictionary.installOrUpdate(
        onProgress: (value) {
          if (mounted) setState(() => _dictionaryProgress = value);
        },
      );
      final version = await dictionary.installedVersion;
      if (mounted) {
        setState(() => _message = 'Offline dictionary installed ($version).');
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _message = 'Dictionary installation failed: $error');
      }
    } finally {
      await dictionary?.close();
      if (mounted) setState(() => _installingDictionary = false);
    }
  }

  Future<void> _removeDocument(
    StudyLibraryService library,
    StudyDocument document,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove PDF?'),
        content: Text('Remove “${document.title}” from this device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await library.removeDocument(document);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<StudyLibraryService>(
      future: _libraryFuture,
      builder: (context, snapshot) {
        final library = snapshot.data;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Japanese Study'),
            actions: [
              IconButton(
                tooltip: 'Install or update offline dictionary',
                onPressed: library == null || _installingDictionary
                    ? null
                    : () => _installDictionary(library),
                icon: const Icon(Icons.menu_book_outlined),
              ),
              IconButton(
                tooltip: 'Import PDF',
                onPressed: library == null || _importing ? null : _importPdf,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          body: snapshot.hasError
              ? Center(
                  child: Text(
                    'Could not open study library: ${snapshot.error}',
                  ),
                )
              : library == null
              ? const Center(child: CircularProgressIndicator())
              : _buildLibrary(library),
          floatingActionButton: library == null || _importing
              ? null
              : FloatingActionButton.extended(
                  onPressed: _importPdf,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Import PDF'),
                ),
        );
      },
    );
  }

  Widget _buildLibrary(StudyLibraryService library) {
    return FutureBuilder<List<StudyDocument>>(
      future: library.listDocuments(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Could not load PDFs: ${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final documents = snapshot.data!;
        return Column(
          children: [
            if (_importing || _installingDictionary)
              const LinearProgressIndicator(),
            if (_installingDictionary)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  'Installing offline dictionary ${(100 * _dictionaryProgress).round()}%',
                ),
              ),
            if (_message != null)
              MaterialBanner(
                content: Text(_message!),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _message = null),
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            const ListTile(
              title: Text('Your PDFs stay on this device.'),
              subtitle: Text(
                'A temporary copy is sent to your configured server for text extraction and OCR.',
              ),
              leading: Icon(Icons.lock_outline),
            ),
            const Divider(height: 1),
            Expanded(
              child: documents.isEmpty
                  ? const Center(
                      child: Text('Import a Japanese PDF to start reading.'),
                    )
                  : ListView.builder(
                      itemCount: documents.length,
                      itemBuilder: (context, index) {
                        final document = documents[index];
                        return ListTile(
                          leading: const Icon(Icons.picture_as_pdf),
                          title: Text(
                            document.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            document.pageCount == null
                                ? 'Page ${document.pageNumber}'
                                : 'Page ${document.pageNumber} of ${document.pageCount}',
                          ),
                          onTap: () => _openDocument(document),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'remove') {
                                _removeDocument(library, document);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'remove',
                                child: Text('Remove from device'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                LocalJapaneseDictionary.attribution,
                style: TextStyle(fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        );
      },
    );
  }
}

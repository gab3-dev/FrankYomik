import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/study_document.dart';
import '../services/local_japanese_dictionary.dart';
import '../services/mlkit_japanese_text_extractor.dart';
import '../services/study_library_service.dart';

class StudyReaderScreen extends ConsumerStatefulWidget {
  final StudyDocument document;

  const StudyReaderScreen({super.key, required this.document});

  @override
  ConsumerState<StudyReaderScreen> createState() => _StudyReaderScreenState();
}

class _StudyReaderScreenState extends ConsumerState<StudyReaderScreen> {
  final PdfViewerController _viewerController = PdfViewerController();
  final Map<int, List<StudyMlKitCrop>> _crops = {};

  StudyLibraryService? _library;
  LocalJapaneseDictionary? _dictionary;
  int _pageNumber = 1;
  int? _pageCount;
  bool _installingDictionary = false;
  bool _cropMode = false;
  int? _cropSelectionPage;
  Offset? _cropSelectionStart;
  Rect? _cropSelection;
  _PendingCrop? _pendingCrop;
  String? _status;

  @override
  void initState() {
    super.initState();
    _pageNumber = widget.document.pageNumber;
    unawaited(_openLocalServices());
  }

  Future<void> _openLocalServices() async {
    try {
      final library = await StudyLibraryService.open();
      final dictionary = await LocalJapaneseDictionary.open(
        library.studyDirectory,
      );
      if (!mounted) {
        await dictionary.close();
        return;
      }
      setState(() {
        _library = library;
        _dictionary = dictionary;
      });
      await _loadCrops(_pageNumber);
      if (_viewerController.isReady) {
        await _saveProgress(_pageNumber);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _status = 'Local study data unavailable: $error');
      }
    }
  }

  void _onViewerReady(PdfDocument _, PdfViewerController controller) {
    _pageCount = controller.pageCount;
    _pageNumber = controller.pageNumber ?? widget.document.pageNumber;
    unawaited(_loadCrops(_pageNumber));
    _saveProgress(_pageNumber);
    if (mounted) setState(() {});
  }

  void _onPageChanged(int? pageNumber) {
    if (pageNumber == null) return;
    setState(() {
      _pageNumber = pageNumber;
      _cropMode = false;
      _cropSelectionPage = null;
      _cropSelectionStart = null;
      _cropSelection = null;
    });
    _saveProgress(pageNumber);
    unawaited(_loadCrops(pageNumber));
  }

  Future<void> _saveProgress(int page) async {
    final library = _library;
    final pageCount = _pageCount;
    if (library == null) return;
    try {
      await library.updateProgress(
        widget.document,
        pageNumber: page,
        pageCount: pageCount,
      );
    } on Object catch (error) {
      debugPrint('[Study] Could not save reading progress: $error');
    }
  }

  Future<void> _loadCrops(int page) async {
    final library = _library;
    if (library == null) return;
    final crops = await library.getMlKitCrops(widget.document.id, page);
    if (mounted && page == _pageNumber) {
      setState(() => _crops[page] = crops);
    }
  }

  Future<void> _startCrop() async {
    if (!MlKitJapaneseTextExtractor.isSupported) {
      _showMessage('ML Kit Japanese OCR is available on Android and iOS only.');
      return;
    }
    setState(() {
      _cropMode = true;
      _cropSelectionPage = null;
      _cropSelectionStart = null;
      _cropSelection = null;
    });
  }

  void _cancelCrop() {
    setState(() {
      _cropMode = false;
      _cropSelectionPage = null;
      _cropSelectionStart = null;
      _cropSelection = null;
    });
  }

  void _beginCropSelection(int pageNumber, Offset position, Size pageSize) {
    final point = _normalizedPoint(position, pageSize);
    setState(() {
      _cropSelectionPage = pageNumber;
      _cropSelectionStart = point;
      _cropSelection = Rect.fromPoints(point, point);
    });
  }

  void _updateCropSelection(int pageNumber, Offset position, Size pageSize) {
    final start = _cropSelectionStart;
    if (start == null || _cropSelectionPage != pageNumber) return;
    setState(() {
      _cropSelection = Rect.fromPoints(
        start,
        _normalizedPoint(position, pageSize),
      );
    });
  }

  void _finishCropSelection(int pageNumber, Size pageSize) {
    final crop = _cropSelection;
    if (crop == null || _cropSelectionPage != pageNumber) return;
    if (crop.width * pageSize.width < 18 ||
        crop.height * pageSize.height < 18) {
      setState(() {
        _cropSelectionStart = null;
        _cropSelection = null;
      });
      _showMessage('Drag a larger rectangle around the text.');
      return;
    }
    _cancelCrop();
    unawaited(_readCrop(pageNumber, crop));
  }

  Offset _normalizedPoint(Offset position, Size pageSize) => Offset(
    (position.dx / pageSize.width).clamp(0, 1).toDouble(),
    (position.dy / pageSize.height).clamp(0, 1).toDouble(),
  );

  Future<void> _readCrop(int page, Rect crop) async {
    setState(() => _pendingCrop = _PendingCrop(pageNumber: page, rect: crop));
    try {
      final text = await MlKitJapaneseTextExtractor().extractCrop(
        pdfPath: widget.document.path,
        pageNumber: page,
        crop: crop,
      );
      if (text.isEmpty) throw StateError('ML Kit found no text in this crop.');
      final now = DateTime.now();
      final saved = StudyMlKitCrop(
        id: now.microsecondsSinceEpoch,
        documentId: widget.document.id,
        pageNumber: page,
        left: crop.left,
        top: crop.top,
        right: crop.right,
        bottom: crop.bottom,
        text: text,
        createdAt: now,
      );
      await _library?.saveMlKitCrop(saved);
      if (mounted) {
        setState(() {
          _crops.putIfAbsent(page, () => []).add(saved);
          _pendingCrop = null;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _pendingCrop = null);
        if (_pageNumber == page) {
          _showMessage('Could not read this crop: $error');
        }
      }
    }
  }

  List<Widget> _buildCropOverlays(
    BuildContext context,
    Rect pageRect,
    PdfPage page,
  ) {
    final crops = [...?_crops[page.pageNumber]];
    final pending = _pendingCrop;
    if (pending != null && pending.pageNumber == page.pageNumber) {
      crops.add(pending.asCrop(widget.document.id));
    }
    return [
      for (final crop in crops)
        Positioned(
          left: crop.left * pageRect.width,
          top: crop.top * pageRect.height,
          width: crop.right * pageRect.width - crop.left * pageRect.width,
          height: crop.bottom * pageRect.height - crop.top * pageRect.height,
          child: _CropTextOverlay(
            crop: crop,
            isPending: pending?.matches(crop) ?? false,
            onTap: (index) => unawaited(_showLookup(crop.text, index)),
          ),
        ),
      if (_cropMode && page.pageNumber == _pageNumber)
        Positioned.fill(
          child: _CropSelectionOverlay(
            selection: _cropSelectionPage == page.pageNumber
                ? _cropSelection
                : null,
            onStart: (position) =>
                _beginCropSelection(page.pageNumber, position, pageRect.size),
            onUpdate: (position) =>
                _updateCropSelection(page.pageNumber, position, pageRect.size),
            onEnd: () => _finishCropSelection(page.pageNumber, pageRect.size),
            onCancel: _cancelCrop,
          ),
        ),
    ];
  }

  Future<void> _showLookup(
    String text,
    int index, {
    String? preferredForm,
    String? surfaceHint,
    String? readingHint,
    List<String> partOfSpeechHint = const [],
  }) async {
    final dictionary = _dictionary;
    JapaneseLookupResult? result;
    String? error;
    if (dictionary == null) {
      error = 'Local dictionary is still opening.';
    } else {
      try {
        result = await dictionary.lookupAt(
          text: text,
          characterIndex: index,
          preferredForm: preferredForm,
          surfaceHint: surfaceHint,
          readingHint: readingHint,
          partOfSpeechHint: partOfSpeechHint,
        );
      } on StateError catch (e) {
        error = e.message;
      }
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _LookupSheet(
        text: text,
        index: index,
        result: result,
        error: error,
        onInstallDictionary: _installDictionary,
      ),
    );
  }

  Future<void> _installDictionary() async {
    final dictionary = _dictionary;
    if (dictionary == null || _installingDictionary) return;
    setState(() {
      _installingDictionary = true;
      _status = 'Downloading the offline Japanese dictionary…';
    });
    try {
      await dictionary.installOrUpdate();
      if (mounted) setState(() => _status = 'Offline dictionary ready.');
    } on Object catch (error) {
      if (mounted) {
        setState(() => _status = 'Dictionary installation failed: $error');
      }
    } finally {
      if (mounted) setState(() => _installingDictionary = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    final dictionary = _dictionary;
    if (dictionary != null) unawaited(dictionary.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.document.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: _cropMode ? 'Cancel crop' : 'Crop Japanese text',
            icon: Icon(_cropMode ? Icons.close : Icons.crop),
            onPressed: _cropMode ? _cancelCrop : _startCrop,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_installingDictionary) const LinearProgressIndicator(),
          if (_status != null)
            MaterialBanner(
              content: Text(_status!),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _status = null),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          Expanded(
            child: File(widget.document.path).existsSync()
                ? PdfViewer.file(
                    widget.document.path,
                    controller: _viewerController,
                    initialPageNumber: widget.document.pageNumber,
                    params: PdfViewerParams(
                      onViewerReady: _onViewerReady,
                      onPageChanged: _onPageChanged,
                      pageOverlaysBuilder: _buildCropOverlays,
                      textSelectionParams: const PdfTextSelectionParams(
                        enabled: false,
                      ),
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                    ),
                  )
                : Center(
                    child: Text(
                      'The local PDF is missing: ${widget.document.path}',
                    ),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Text(
                    'Page $_pageNumber${_pageCount == null ? '' : ' / $_pageCount'}',
                  ),
                  const Spacer(),
                  Text(
                    _cropMode
                        ? 'Drag around a speech bubble or text area'
                        : 'Crop text, then tap it for a dictionary lookup',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingCrop {
  final int pageNumber;
  final Rect rect;

  const _PendingCrop({required this.pageNumber, required this.rect});

  StudyMlKitCrop asCrop(String documentId) => StudyMlKitCrop(
    id: -1,
    documentId: documentId,
    pageNumber: pageNumber,
    left: rect.left,
    top: rect.top,
    right: rect.right,
    bottom: rect.bottom,
    text: 'Reading…',
    createdAt: DateTime.now(),
  );

  bool matches(StudyMlKitCrop crop) => crop.id == -1;
}

class _CropSelectionOverlay extends StatelessWidget {
  final Rect? selection;
  final ValueChanged<Offset> onStart;
  final ValueChanged<Offset> onUpdate;
  final VoidCallback onEnd;
  final VoidCallback onCancel;

  const _CropSelectionOverlay({
    required this.selection,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) => onStart(details.localPosition),
        onPanUpdate: (details) => onUpdate(details.localPosition),
        onPanEnd: (_) => onEnd(),
        onPanCancel: onCancel,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.08),
              ),
            ),
            if (selection != null)
              Positioned.fromRect(
                rect: Rect.fromLTRB(
                  selection!.left * constraints.maxWidth,
                  selection!.top * constraints.maxHeight,
                  selection!.right * constraints.maxWidth,
                  selection!.bottom * constraints.maxHeight,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.lightBlueAccent.withValues(alpha: 0.2),
                    border: Border.all(color: Colors.lightBlueAccent, width: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CropTextOverlay extends StatelessWidget {
  final StudyMlKitCrop crop;
  final bool isPending;
  final ValueChanged<int> onTap;

  const _CropTextOverlay({
    required this.crop,
    required this.isPending,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const padding = EdgeInsets.all(6);
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: Colors.white, height: 1.1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.black87,
            border: Border.all(
              color: isPending ? Colors.amber : Colors.lightBlueAccent,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: isPending
              ? const Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : Text(
                  crop.text,
                  style: style,
                  overflow: TextOverflow.fade,
                  maxLines: 12,
                ),
        );
        if (isPending) return content;
        return PdfOverlayInteractionRegion(
          onTap: (details) {
            final painter =
                TextPainter(
                  text: TextSpan(text: crop.text, style: style),
                  textDirection: TextDirection.ltr,
                  maxLines: 12,
                )..layout(
                  maxWidth: (constraints.maxWidth - padding.horizontal).clamp(
                    1,
                    double.infinity,
                  ),
                );
            final position = painter.getPositionForOffset(
              details.localPosition - const Offset(6, 6),
            );
            onTap(position.offset.clamp(0, crop.text.length - 1));
            return true;
          },
          child: content,
        );
      },
    );
  }
}

class _LookupSheet extends StatelessWidget {
  final String text;
  final int index;
  final JapaneseLookupResult? result;
  final String? error;
  final Future<void> Function() onInstallDictionary;

  const _LookupSheet({
    required this.text,
    required this.index,
    required this.result,
    required this.error,
    required this.onInstallDictionary,
  });

  @override
  Widget build(BuildContext context) {
    final character = result?.character ?? _characterAt(text, index) ?? '';
    final matches = result?.words ?? const <JapaneseWordMatch>[];
    final kanji = result?.kanji;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(character, style: Theme.of(context).textTheme.displaySmall),
              if (matches.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final match in matches) ...[
                  Text(
                    result?.surfaceHint ?? match.form,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (result?.surfaceHint != null &&
                      result!.surfaceHint != match.form)
                    Text('Dictionary form: ${match.form}'),
                  if (match.readings.isNotEmpty || result?.readingHint != null)
                    Text(
                      match.readings.isNotEmpty
                          ? match.readings.join(' · ')
                          : result!.readingHint!,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  for (final sense in match.senses) ...[
                    if ((sense['part_of_speech'] as List<dynamic>? ?? const [])
                        .isNotEmpty)
                      Text(
                        (sense['part_of_speech'] as List<dynamic>).join(' · '),
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        (sense['glosses'] as List<dynamic>? ?? const []).join(
                          '; ',
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                ],
              ] else if (error != null) ...[
                Text(error!),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await onInstallDictionary();
                  },
                  icon: const Icon(Icons.download),
                  label: const Text('Install offline dictionary'),
                ),
              ] else ...[
                const Text('No word entry found for this context.'),
              ],
              if (kanji != null) ...[
                const Divider(height: 24),
                Text(
                  'Kanji: ${kanji.literal}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (kanji.readings.isNotEmpty)
                  Text('Readings: ${kanji.readings.join(' · ')}'),
                if (kanji.meanings.isNotEmpty)
                  Text('Meanings: ${kanji.meanings.join('; ')}'),
              ],
              if (matches.isEmpty && result?.readingHint != null)
                Text('Reading: ${result!.readingHint}'),
              if (result?.partOfSpeechHint.isNotEmpty == true)
                Text('Part of speech: ${result!.partOfSpeechHint.join(' · ')}'),
              if (matches.isEmpty && kanji == null && error == null)
                Text('Selected text: $character'),
            ],
          ),
        ),
      ),
    );
  }
}

String? _characterAt(String value, int codeUnitIndex) {
  if (codeUnitIndex < 0 || codeUnitIndex >= value.length) return null;
  var offset = 0;
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    if (codeUnitIndex < offset + character.length) return character;
    offset += character.length;
  }
  return null;
}

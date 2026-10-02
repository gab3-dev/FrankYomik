import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/page_job.dart';
import '../models/server_settings.dart';
import '../providers/jobs_provider.dart';
import '../providers/settings_provider.dart';

class ImageTranslateScreen extends ConsumerStatefulWidget {
  const ImageTranslateScreen({super.key});

  @override
  ConsumerState<ImageTranslateScreen> createState() =>
      _ImageTranslateScreenState();
}

class _ImageTranslateScreenState extends ConsumerState<ImageTranslateScreen> {
  final List<_PickedImage> _images = [];
  String _pipeline = 'manga_translate';
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pipeline = ref.read(settingsProvider).pipeline;
    });
  }

  Future<void> _pickImages() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    final newImages = <_PickedImage>[];
    for (final file in result.files) {
      if (file.path == null) continue;
      final bytes = await File(file.path!).readAsBytes();
      newImages.add(_PickedImage(
        name: file.name,
        path: file.path!,
        bytes: bytes,
        pageId: const Uuid().v4(),
      ));
    }
    setState(() => _images.addAll(newImages));
  }

  void _removeImage(int index) {
    setState(() => _images.removeAt(index));
  }

  Future<void> _submitAll() async {
    if (_images.isEmpty) return;

    final jobs = ref.read(jobsProvider);
    final pending = _images.where((img) => !jobs.containsKey(img.pageId)).toList();
    if (pending.isEmpty) return;

    setState(() => _submitting = true);

    final notifier = ref.read(jobsProvider.notifier);
    for (final img in pending) {
      final idx = _images.indexOf(img);
      await notifier.submitPage(
        pageId: img.pageId,
        imageBytes: img.bytes,
        pipeline: _pipeline,
        pageNumber: '${idx + 1}',
      );
    }

    setState(() => _submitting = false);
  }

  void _openViewer(int initialIndex) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ImageViewerScreen(
          images: _images,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final jobs = ref.watch(jobsProvider);
    final hasPending =
        _images.any((img) => !jobs.containsKey(img.pageId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Translate Images'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_photo_alternate),
            tooltip: 'Add images',
            onPressed: _submitting ? null : _pickImages,
          ),
        ],
      ),
      body: _images.isEmpty ? _buildEmpty() : _buildList(jobs),
      floatingActionButton: _images.isEmpty || _submitting || !hasPending
          ? null
          : FloatingActionButton.extended(
              onPressed: _submitAll,
              icon: const Icon(Icons.translate),
              label: const Text('Translate All'),
            ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_search, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            'No images selected',
            style: TextStyle(fontSize: 18, color: Colors.grey[600]),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _pickImages,
            icon: const Icon(Icons.add_photo_alternate),
            label: const Text('Pick Images'),
          ),
        ],
      ),
    );
  }

  Widget _buildList(Map<String, PageJob> jobs) {
    return Column(
      children: [
        // Pipeline selector
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Text('Pipeline: '),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _pipeline,
                onChanged: _submitting
                    ? null
                    : (v) => setState(() => _pipeline = v!),
                items: ServerSettings.pipelines
                    .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                    .toList(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Image list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 80),
            itemCount: _images.length,
            itemBuilder: (ctx, i) {
              final img = _images[i];
              final job = jobs[img.pageId];
              return _ImageTile(
                image: img,
                job: job,
                onRemove: _submitting ? null : () => _removeImage(i),
                onTap: () => _openViewer(i),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PickedImage {
  final String name;
  final String path;
  final Uint8List bytes;
  final String pageId;

  _PickedImage({
    required this.name,
    required this.path,
    required this.bytes,
    required this.pageId,
  });
}

class _ImageTile extends StatelessWidget {
  final _PickedImage image;
  final PageJob? job;
  final VoidCallback? onRemove;
  final VoidCallback? onTap;

  const _ImageTile({
    required this.image,
    this.job,
    this.onRemove,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Source image thumbnail
          GestureDetector(
            onTap: onTap,
            child: SizedBox(
              height: 200,
              child: _buildImage(),
            ),
          ),
          // Status bar
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(child: _buildStatus()),
                if (onRemove != null && job == null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: onRemove,
                    tooltip: 'Remove',
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImage() {
    // Show translated image if available, otherwise source
    if (job?.translatedImage != null) {
      return Image.memory(
        job!.translatedImage!,
        fit: BoxFit.contain,
      );
    }
    return Image.memory(
      image.bytes,
      fit: BoxFit.contain,
    );
  }

  Widget _buildStatus() {
    if (job == null) {
      return Text(
        image.name,
        style: const TextStyle(fontWeight: FontWeight.w500),
        overflow: TextOverflow.ellipsis,
      );
    }

    final status = job!;
    final label = switch (status.status) {
      PageJobStatus.pending => 'Pending...',
      PageJobStatus.queued => 'Queued...',
      PageJobStatus.processing =>
        status.stage != null
            ? '${status.stage} ${status.percent}%'
            : 'Processing...',
      PageJobStatus.completed =>
        status.cached ? 'Completed (cached)' : 'Completed',
      PageJobStatus.failed => 'Failed: ${status.error ?? "unknown"}',
    };

    final color = switch (status.status) {
      PageJobStatus.completed => Colors.green,
      PageJobStatus.failed => Colors.red,
      _ => Colors.orange,
    };

    return Row(
      children: [
        if (status.isActive)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (status.isComplete)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Icon(Icons.check_circle, size: 18, color: Colors.green),
          ),
        if (status.isFailed)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Icon(Icons.error, size: 18, color: Colors.red),
          ),
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

}

class _ImageViewerScreen extends ConsumerStatefulWidget {
  final List<_PickedImage> images;
  final int initialIndex;

  const _ImageViewerScreen({
    required this.images,
    required this.initialIndex,
  });

  @override
  ConsumerState<_ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends ConsumerState<_ImageViewerScreen> {
  late final PageController _pageController;
  late int _currentIndex;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    if (index < 0 || index >= widget.images.length) return;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _goTo(_currentIndex - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _goTo(_currentIndex + 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.pop(context);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final jobs = ref.watch(jobsProvider);

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(
            '${_currentIndex + 1} / ${widget.images.length}',
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios),
              onPressed: _currentIndex > 0
                  ? () => _goTo(_currentIndex - 1)
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_ios),
              onPressed: _currentIndex < widget.images.length - 1
                  ? () => _goTo(_currentIndex + 1)
                  : null,
            ),
          ],
        ),
        body: PageView.builder(
          controller: _pageController,
          itemCount: widget.images.length,
          onPageChanged: (i) => setState(() => _currentIndex = i),
          itemBuilder: (ctx, i) {
            final img = widget.images[i];
            final job = jobs[img.pageId];
            final bytes = job?.translatedImage ?? img.bytes;
            final isTranslated = job?.translatedImage != null;
            return Column(
              children: [
                Expanded(
                  child: InteractiveViewer(
                    child: Center(
                      child: Image.memory(bytes, fit: BoxFit.contain),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: _ViewerStatus(
                    name: img.name,
                    job: job,
                    isTranslated: isTranslated,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ViewerStatus extends StatelessWidget {
  final String name;
  final PageJob? job;
  final bool isTranslated;

  const _ViewerStatus({
    required this.name,
    this.job,
    required this.isTranslated,
  });

  @override
  Widget build(BuildContext context) {
    if (job == null) {
      return Text(name, style: const TextStyle(color: Colors.white70));
    }
    final s = job!;
    final label = switch (s.status) {
      PageJobStatus.pending => 'Pending...',
      PageJobStatus.queued => 'Queued...',
      PageJobStatus.processing =>
        s.stage != null ? '${s.stage} ${s.percent}%' : 'Processing...',
      PageJobStatus.completed =>
        isTranslated ? 'Translated' : 'Completed',
      PageJobStatus.failed => 'Failed: ${s.error ?? "unknown"}',
    };
    final color = switch (s.status) {
      PageJobStatus.completed => Colors.greenAccent,
      PageJobStatus.failed => Colors.redAccent,
      _ => Colors.orangeAccent,
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (s.isActive)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.orangeAccent,
              ),
            ),
          ),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

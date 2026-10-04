import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

/// Runs ML Kit's mobile Japanese recognizer on one selected PDF rectangle.
class MlKitJapaneseTextExtractor {
  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  Future<String> extractCrop({
    required String pdfPath,
    required int pageNumber,
    required Rect crop,
  }) async {
    if (!isSupported) {
      throw UnsupportedError(
        'ML Kit Japanese OCR is available on Android and iOS only.',
      );
    }
    if (crop.width <= 0 || crop.height <= 0) {
      throw ArgumentError.value(crop, 'crop', 'must have a positive size');
    }

    final document = await PdfDocument.openFile(pdfPath);
    PdfImage? pageImage;
    File? inputFile;
    TextRecognizer? recognizer;
    try {
      final page = _pageAt(document, pageNumber);
      const targetLongestSide = 1800.0;
      final scale =
          targetLongestSide /
          math.max(page.width * crop.width, page.height * crop.height);
      final fullWidth = page.width * scale;
      final fullHeight = page.height * scale;
      pageImage = await page.render(
        x: (crop.left * fullWidth).round(),
        y: (crop.top * fullHeight).round(),
        width: (crop.width * fullWidth).round(),
        height: (crop.height * fullHeight).round(),
        fullWidth: fullWidth,
        fullHeight: fullHeight,
      );
      if (pageImage == null) {
        throw StateError('Could not render PDF crop for ML Kit OCR.');
      }

      final directory = await getTemporaryDirectory();
      inputFile = File(
        p.join(
          directory.path,
          'frank-yomik-mlkit-crop-$pageNumber-${DateTime.now().microsecondsSinceEpoch}.png',
        ),
      );
      await inputFile.writeAsBytes(_toPngBytes(pageImage), flush: true);

      recognizer = TextRecognizer(script: TextRecognitionScript.japanese);
      final result = await recognizer.processImage(
        InputImage.fromFile(inputFile),
      );
      return result.text.trim();
    } finally {
      await recognizer?.close();
      pageImage?.dispose();
      await document.dispose();
      if (inputFile != null) {
        try {
          await inputFile.delete();
        } on FileSystemException {
          // The OS can remove a stale temporary image later.
        }
      }
    }
  }

  PdfPage _pageAt(PdfDocument document, int pageNumber) {
    if (pageNumber < 1 || pageNumber > document.pages.length) {
      throw RangeError.range(
        pageNumber,
        1,
        document.pages.length,
        'pageNumber',
      );
    }
    return document.pages[pageNumber - 1];
  }

  Uint8List _toPngBytes(PdfImage image) {
    final rendered = img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: image.pixels.buffer,
      bytesOffset: image.pixels.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.bgra,
    );
    return Uint8List.fromList(img.encodePng(rendered));
  }
}

class StudyDocument {
  final String id;
  final String title;
  final String path;
  final int pageNumber;
  final int? pageCount;
  final String? serverDocumentId;
  final DateTime addedAt;

  const StudyDocument({
    required this.id,
    required this.title,
    required this.path,
    required this.pageNumber,
    required this.pageCount,
    required this.serverDocumentId,
    required this.addedAt,
  });

  factory StudyDocument.fromRow(Map<String, Object?> row) {
    return StudyDocument(
      id: row['document_id']! as String,
      title: row['title']! as String,
      path: row['path']! as String,
      pageNumber: row['page_number'] as int? ?? 1,
      pageCount: row['page_count'] as int?,
      serverDocumentId: row['server_document_id'] as String?,
      addedAt: DateTime.fromMillisecondsSinceEpoch(row['added_at']! as int),
    );
  }

  StudyDocument copyWith({
    int? pageNumber,
    int? pageCount,
    String? serverDocumentId,
    bool clearServerDocumentId = false,
  }) {
    return StudyDocument(
      id: id,
      title: title,
      path: path,
      pageNumber: pageNumber ?? this.pageNumber,
      pageCount: pageCount ?? this.pageCount,
      serverDocumentId: clearServerDocumentId
          ? null
          : serverDocumentId ?? this.serverDocumentId,
      addedAt: addedAt,
    );
  }
}

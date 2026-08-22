enum TransferDirection { send, receive }

class TransferRecord {
  final String id;
  final String fileName;
  final int fileBytesSize;
  final String fileExtensionType;
  final DateTime timestamp;
  final TransferDirection direction;
  final bool isSuccessful;

  TransferRecord({
    required this.id,
    required this.fileName,
    required this.fileBytesSize,
    required this.fileExtensionType,
    required this.timestamp,
    required this.direction,
    this.isSuccessful = true,
  });

  // Human-readable size converter helper
  String get formattedSize {
    if (fileBytesSize < 1024) return '$fileBytesSize B';
    if (fileBytesSize < 1024 * 1024) return '${(fileBytesSize / 1024).toStringAsFixed(1)} KB';
    return '${(fileBytesSize / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

import 'dart:typed_data';

enum TransferItemType { file, app }

class TransferItem {
  final String id;
  final String name;
  final String path;
  final int size;
  final TransferItemType type;
  final Uint8List? icon; // For app icons or file thumbnails

  TransferItem({
    required this.id,
    required this.name,
    required this.path,
    required this.size,
    required this.type,
    this.icon,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'size': size,
      'type': type.toString().split('.').last,
    };
  }
}

class Device {
  final String id;
  final String name;
  final String ip;
  final int port; // For HTTP server, usually fixed or discovered.

  Device({
    required this.id,
    required this.name,
    required this.ip,
    this.port = 8080, // Default port for file server
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Device && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

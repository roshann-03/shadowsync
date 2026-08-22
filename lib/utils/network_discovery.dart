import "dart:io";

class NetworkDiscovery {
  static Future<String> getAvailableIp() async {
    try {
      List<NetworkInterface> interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      List<String> physicalAddresses = [];
      List<String> virtualAddresses = [];

      for (var iInterface in interfaces) {
        String name = iInterface.name.toLowerCase();

        if (iInterface.addresses.isEmpty) continue;
        String ipAddress = iInterface.addresses.first.address;

        bool isVirtual =
            name.contains('vethernet') ||
            name.contains('wsl') ||
            name.contains('virtualbox') ||
            name.contains('vmware') ||
            name.contains('vbox') ||
            name.contains('host-only') ||
            name.contains('sandbox');

        if (isVirtual) {
          virtualAddresses.add(ipAddress);
        } else {
          physicalAddresses.add(ipAddress);
        }
      }

      if (physicalAddresses.isNotEmpty) {
        return physicalAddresses.first;
      } else {
        return virtualAddresses.first;
      }
    } catch (e) {}
    return "127.0.0.1";
  }
}

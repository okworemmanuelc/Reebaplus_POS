import 'package:reebaplus_pos/shared/services/usb_printer_channel.dart';

/// Scripted USB printer channel (#614): no platform channel, records every
/// permission request and write.
class FakeUsbPrinterChannel implements UsbPrinterChannel {
  FakeUsbPrinterChannel({
    List<UsbPrinterInfo>? printers,
    this.grantPermission = true,
    this.writeSucceeds = true,
    this.isSupported = true,
  }) : printers = printers ?? [];

  List<UsbPrinterInfo> printers;
  bool grantPermission;
  bool writeSucceeds;

  @override
  final bool isSupported;

  final List<String> permissionRequests = [];
  final List<(String, List<int>)> writes = [];

  @override
  Future<List<UsbPrinterInfo>> list() async => List.of(printers);

  @override
  Future<bool> requestPermission(String id) async {
    permissionRequests.add(id);
    if (grantPermission) {
      printers = [
        for (final p in printers)
          p.id == id ? p.copyWith(hasPermission: true) : p,
      ];
    }
    return grantPermission;
  }

  @override
  Future<bool> write(String id, List<int> bytes) async {
    writes.add((id, bytes));
    return writeSucceeds;
  }
}

UsbPrinterInfo fakeUsbPrinter({
  String id = 'usb:1208:514',
  String name = 'TM-T20',
  bool hasPermission = true,
}) => UsbPrinterInfo(
  id: id,
  name: name,
  vendorId: 1208,
  productId: 514,
  hasPermission: hasPermission,
);

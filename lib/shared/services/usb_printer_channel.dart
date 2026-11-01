import 'dart:io';

import 'package:flutter/services.dart';

import 'package:reebaplus_pos/core/utils/logger.dart';

/// A USB receipt printer attached to this device (#614).
class UsbPrinterInfo {
  const UsbPrinterInfo({
    required this.id,
    required this.name,
    required this.vendorId,
    required this.productId,
    required this.hasPermission,
  });

  /// `usb:<vendorId>:<productId>[:<serial>]`. Paper size and print style are
  /// saved under this id, the way Bluetooth printers use their MAC.
  final String id;
  final String name;
  final int vendorId;
  final int productId;

  /// Whether Android already lets the app talk to this printer.
  final bool hasPermission;

  UsbPrinterInfo copyWith({bool? hasPermission}) => UsbPrinterInfo(
    id: id,
    name: name,
    vendorId: vendorId,
    productId: productId,
    hasPermission: hasPermission ?? this.hasPermission,
  );
}

/// Talks to the app's own Android USB printer code (`UsbPrinterPlugin.kt`).
/// Abstract so tests can swap in a fake, like the Bluetooth `writeBytes` seam
/// in `PrinterService`.
abstract class UsbPrinterChannel {
  /// The real channel. Off Android it lists nothing and never writes.
  factory UsbPrinterChannel() = MethodChannelUsbPrinterChannel;

  /// True only where USB printing exists at all (Android).
  bool get isSupported;

  /// Attached USB printers. Empty when none, or off Android.
  Future<List<UsbPrinterInfo>> list();

  /// Shows Android's "Allow Reebaplus to access this USB device?" prompt.
  /// True when access was granted (or already held).
  Future<bool> requestPermission(String id);

  /// Sends [bytes] to the printer. True only if every byte went out.
  Future<bool> write(String id, List<int> bytes);
}

class MethodChannelUsbPrinterChannel implements UsbPrinterChannel {
  MethodChannelUsbPrinterChannel({MethodChannel? channel, bool? isAndroid})
    : _channel = channel ?? const MethodChannel('reebaplus/usb_printer'),
      _isAndroid = isAndroid ?? Platform.isAndroid;

  final MethodChannel _channel;
  final bool _isAndroid;

  @override
  bool get isSupported => _isAndroid;

  @override
  Future<List<UsbPrinterInfo>> list() async {
    if (!_isAndroid) return const [];
    try {
      final raw = await _channel.invokeListMethod<Object?>('list') ?? const [];
      return [
        for (final item in raw)
          if (item is Map) _fromMap(item),
      ];
    } catch (e) {
      AppLogger.error('USB printer list failed: $e');
      return const [];
    }
  }

  @override
  Future<bool> requestPermission(String id) async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('requestPermission', {
            'id': id,
          }) ??
          false;
    } catch (e) {
      AppLogger.error('USB printer permission request failed: $e');
      return false;
    }
  }

  @override
  Future<bool> write(String id, List<int> bytes) async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('write', {
            'id': id,
            'bytes': Uint8List.fromList(bytes),
          }) ??
          false;
    } catch (e) {
      AppLogger.error('USB printer write failed: $e');
      return false;
    }
  }

  static UsbPrinterInfo _fromMap(Map<Object?, Object?> m) => UsbPrinterInfo(
    id: m['id'] as String? ?? '',
    name: m['name'] as String? ?? 'USB printer',
    vendorId: (m['vendorId'] as num?)?.toInt() ?? 0,
    productId: (m['productId'] as num?)?.toInt() ?? 0,
    hasPermission: m['hasPermission'] as bool? ?? false,
  );
}

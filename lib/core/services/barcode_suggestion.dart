import 'dart:typed_data';

/// What the shared barcode catalogue (ADR 0029, #332) suggests for a factory
/// barcode: the consensus name and unit across Reebaplus shops, and the shared
/// photo's raw downloaded bytes and public URL. Any part may be missing.
/// Carries no business identity.
final class BarcodeSuggestion {
  const BarcodeSuggestion({
    this.name,
    this.unit,
    this.photoBytes,
    this.photoUrl,
  });

  /// The most common name, trimmed. Null when nobody suggested one.
  final String? name;

  /// The most common unit, trimmed. Null when no shop gave the product a unit.
  final String? unit;

  /// The shared photo as downloaded (not yet resized). Null when there is no
  /// shared photo or the download failed.
  final Uint8List? photoBytes;

  /// The shared photo's public URL as the catalogue returned it, whether or
  /// not it was downloaded. The report sheet (#335) shows it and sends it back
  /// as what the shop saw.
  final String? photoUrl;

  /// Nothing Add Product can fill in: no name, no unit, no downloaded photo.
  /// A [photoUrl] alone doesn't count (there are no bytes to save).
  bool get isEmpty => name == null && unit == null && photoBytes == null;
}

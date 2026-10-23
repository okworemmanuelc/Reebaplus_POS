/// How long the code just handled is ignored after the scanner resumes (#319),
/// so a barcode still in frame isn't read again the moment the sheet closes.
/// A different code is accepted immediately.
const Duration sameCodeDebounce = Duration(milliseconds: 1500);

/// Decides which camera reads a scan session acts on (#319). Pure — no camera,
/// no widgets — with an injectable clock so the debounce is unit-testable.
///
///  - While a read is being handled ([isBusy]) every other read is ignored.
///  - After [finish] (the camera resumes), the same code is ignored for
///    [window]; any other code is accepted straight away.
class ScanGate {
  ScanGate({this.window = sameCodeDebounce, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Duration window;
  final DateTime Function() _now;

  bool _isBusy = false;
  String? _lastCode;
  DateTime? _resumedAt;

  /// True while a read is being handled (other reads are ignored).
  bool get isBusy => _isBusy;

  /// Claims [code] for handling. Returns false — and changes nothing — when a
  /// read is already being handled, or [code] is the one just handled and the
  /// debounce window since resuming hasn't passed yet.
  bool tryBegin(String code) {
    if (_isBusy) return false;
    final resumedAt = _resumedAt;
    if (code == _lastCode &&
        resumedAt != null &&
        _now().difference(resumedAt) < window) {
      return false;
    }
    _isBusy = true;
    _lastCode = code;
    return true;
  }

  /// Marks the current read handled; the debounce window starts now.
  void finish() {
    if (!_isBusy) return;
    _isBusy = false;
    _resumedAt = _now();
  }
}

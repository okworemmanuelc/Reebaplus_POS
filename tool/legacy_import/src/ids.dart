import 'package:uuid/uuid.dart';

/// Fixed uuid v5 namespace for every id the importer derives. Never change it:
/// a re-run only stays a no-op because the same old id always maps to the same
/// new id.
const String kImportNamespace = '6f1d8b0e-3c52-4c1a-9a57-2f4e8d7b1c90';

/// The new id for an old row. [kind] keeps ids from different old tables apart
/// (and lets one old row derive several new rows, e.g. a stock movement's
/// transaction and its adjustment).
String legacyId(String kind, String oldId) =>
    const Uuid().v5(kImportNamespace, '$kind:$oldId');

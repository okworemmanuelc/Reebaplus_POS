/// The permission-gate module (ADR 0002). One import for call sites: the Gate
/// algebra, the named-gate registry ([Gates]), and the `Guarded` widget +
/// `.allows` / `.allowsNow` / `.require` evaluation forms.
library;

export 'package:reebaplus_pos/core/permissions/gate.dart';
export 'package:reebaplus_pos/core/permissions/gate_registry.dart';
export 'package:reebaplus_pos/core/permissions/guarded.dart';

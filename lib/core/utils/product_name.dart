import 'package:reebaplus_pos/core/utils/name_case.dart';

/// The name a product shows everywhere: what the shop typed, nothing added.
/// It goes through [toNameCase] so names saved before #507 show the same way
/// as new ones.
///
/// The unit and size are never part of it: "Heineken", not "Bottle Heineken"
/// or "Heineken (B)". A shop that sells sizes types them into the name.
/// Screens that need the unit show it separately (a subtitle or chip).
String productDisplayName(String name) => toNameCase(name);

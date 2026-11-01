import 'dart:convert';
import 'dart:io';

/// The role slugs `seed_default_roles_for_business` creates.
const Set<String> kRoleSlugs = {
  'ceo',
  'manager',
  'cashier',
  'stock_keeper',
  'driver',
};

/// A login that joins the new business. [oldProfileId] is null for a login the
/// old app never had (the hidden support CEO).
class Account {
  final String? oldProfileId;
  final String email;
  final String authUid;
  final String? name;
  final String role;
  final bool hidden;

  const Account({
    required this.oldProfileId,
    required this.email,
    required this.authUid,
    required this.name,
    required this.role,
    required this.hidden,
  });

  factory Account.fromJson(Map<String, Object?> json) {
    final role = (json['role'] as String?) ?? 'ceo';
    if (!kRoleSlugs.contains(role)) {
      throw FormatException('Unknown role "$role" in accounts file');
    }
    return Account(
      oldProfileId: json['oldProfileId'] as String?,
      email: (json['email'] as String).trim().toLowerCase(),
      authUid: (json['authUid'] as String).trim().toLowerCase(),
      name: json['name'] as String?,
      role: role,
      hidden: (json['hidden'] as bool?) ?? false,
    );
  }

  /// A dry-run stand-in rather than a real login.
  bool get isPlaceholder => authUid.startsWith('00000000-0000-0000-0000-');
}

/// What the export cannot say about the target: who signs in, and how the old
/// mixed Category table splits. Passed in so no shop detail lives in the repo.
class ImportConfig {
  final String businessId;
  final String businessName;
  final String businessType;
  final String? businessPhone;
  final String? businessEmail;
  final String ownerAuthUid;
  final List<Account> accounts;

  /// Old Category names that are product types; every other one is a company
  /// and becomes a manufacturer. Compared case-insensitively.
  final Set<String> productTypeCategories;

  ImportConfig({
    required this.businessId,
    required this.businessName,
    required this.businessType,
    required this.businessPhone,
    required this.businessEmail,
    required this.ownerAuthUid,
    required this.accounts,
    required Iterable<String> productTypeCategories,
  }) : productTypeCategories = {
         for (final name in productTypeCategories) name.trim().toLowerCase(),
       } {
    if (accounts.isEmpty) {
      throw const FormatException('Accounts file lists no accounts');
    }
    if (!accounts.any((account) => account.authUid == ownerAuthUid)) {
      throw const FormatException('The owner is not in the accounts file');
    }
  }

  bool isProductTypeCategory(String name) =>
      productTypeCategories.contains(name.trim().toLowerCase());

  bool get hasPlaceholderAccounts =>
      accounts.any((account) => account.isPlaceholder);
}

/// Reads `{"accounts": [...], "productTypeCategories": [...]}`.
({List<Account> accounts, List<String> productTypeCategories}) readAccountsFile(
  String path,
) {
  final json =
      jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
  final accounts = (json['accounts'] as List<Object?>)
      .map((row) => Account.fromJson(row as Map<String, Object?>))
      .toList();
  final categories = ((json['productTypeCategories'] as List<Object?>?) ?? [])
      .cast<String>();
  return (accounts: accounts, productTypeCategories: categories);
}

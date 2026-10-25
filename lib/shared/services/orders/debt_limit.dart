/// The Checkout debt-limit gate (§14.3), as one pure rule so the Pay on
/// delivery exception (#432) is tested in the same place as the usual rule.
library;

/// What the gate says about a sale.
sealed class DebtLimitResult {
  const DebtLimitResult();
}

/// The sale may go ahead.
final class DebtLimitOk extends DebtLimitResult {
  const DebtLimitOk();
}

/// The sale would leave the customer in debt and they have no limit set.
final class DebtLimitNotSet extends DebtLimitResult {
  const DebtLimitNotSet();
}

/// The sale would take the customer past their limit by [overByKobo].
final class DebtLimitExceeded extends DebtLimitResult {
  const DebtLimitExceeded({required this.limitKobo, required this.overByKobo});
  final int limitKobo;
  final int overByKobo;
}

/// Checks a sale against the customer's debt limit.
///
/// [balanceKobo] is the spendable balance before the sale (negative = debt).
/// Only a sale that ADDS debt is gated: a fully paid or overpaid sale never is.
///
/// [excludeOwnAmount] is Pay on delivery (#432): this order's own amount is
/// left out, so only the debt the customer ALREADY had is checked, exactly as
/// usual. A new customer with no limit can then be served, while prior debt
/// over the limit (or with no limit set) still blocks.
DebtLimitResult checkDebtLimit({
  required int balanceKobo,
  required int paidKobo,
  required int totalKobo,
  required int limitKobo,
  bool excludeOwnAmount = false,
}) {
  final int projectedKobo;
  if (excludeOwnAmount) {
    projectedKobo = balanceKobo;
  } else {
    if (paidKobo >= totalKobo) return const DebtLimitOk();
    projectedKobo = balanceKobo + paidKobo - totalKobo;
  }
  if (projectedKobo >= 0) return const DebtLimitOk();
  if (limitKobo <= 0) return const DebtLimitNotSet();
  if (projectedKobo < -limitKobo) {
    return DebtLimitExceeded(
      limitKobo: limitKobo,
      overByKobo: (-projectedKobo) - limitKobo,
    );
  }
  return const DebtLimitOk();
}

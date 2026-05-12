/// Client wrapper around the five invite Edge Functions.
///
/// Mirrors the server-side error catalog from supabase/functions/_shared/errors.ts;
/// keep the two enums in sync.
library;

import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/utils/logger.dart';

/// Wire-level error codes returned by the Edge Functions.
enum InviteErrorCode {
  unauthenticated,
  forbidden,
  invalidPayload,
  invalidEmail,
  disposableEmail,
  selfInvite,
  alreadyMember,
  invitePending,
  otherBusinessOwner,
  invalidWarehouse,
  forbiddenRole,
  rateLimited,
  invalidToken,
  expired,
  revoked,
  alreadyUsed,
  emailMismatch,
  internal,
  networkError;

  /// Default user-facing message. Override per-screen if a more specific
  /// phrasing is needed.
  String get defaultMessage => switch (this) {
        InviteErrorCode.unauthenticated => 'Please sign in again.',
        InviteErrorCode.forbidden =>
          'Only managers and owners can send invitations.',
        InviteErrorCode.invalidPayload =>
          'Some details are missing. Please try again.',
        InviteErrorCode.invalidEmail => 'Enter a valid email address.',
        InviteErrorCode.disposableEmail =>
          "Disposable email addresses aren't allowed.",
        InviteErrorCode.selfInvite => "You can't invite yourself.",
        InviteErrorCode.alreadyMember =>
          'This person is already on your team.',
        InviteErrorCode.invitePending =>
          'An invite to this email is already pending.',
        InviteErrorCode.otherBusinessOwner =>
          'This email belongs to the owner of another business.',
        InviteErrorCode.invalidWarehouse =>
          'Pick a warehouse from your business.',
        InviteErrorCode.forbiddenRole =>
          "You can't invite someone as CEO.",
        InviteErrorCode.rateLimited =>
          'Too many invites today. Try again tomorrow.',
        InviteErrorCode.invalidToken => 'This invite link is invalid.',
        InviteErrorCode.expired =>
          'This invite has expired. Ask your manager for a new one.',
        InviteErrorCode.revoked => 'This invite has been cancelled.',
        InviteErrorCode.alreadyUsed =>
          'This invite has already been used.',
        InviteErrorCode.emailMismatch =>
          'This invite was sent to a different email.',
        InviteErrorCode.internal => 'Something went wrong. Please try again.',
        InviteErrorCode.networkError =>
          "Couldn't reach the server. Check your connection.",
      };

  static InviteErrorCode? fromWire(String? wire) {
    if (wire == null) return null;
    return switch (wire) {
      'unauthenticated' => InviteErrorCode.unauthenticated,
      'forbidden' => InviteErrorCode.forbidden,
      'invalid_payload' => InviteErrorCode.invalidPayload,
      'invalid_email' => InviteErrorCode.invalidEmail,
      'disposable_email' => InviteErrorCode.disposableEmail,
      'self_invite' => InviteErrorCode.selfInvite,
      'already_member' => InviteErrorCode.alreadyMember,
      'invite_pending' => InviteErrorCode.invitePending,
      'other_business_owner' => InviteErrorCode.otherBusinessOwner,
      'invalid_warehouse' => InviteErrorCode.invalidWarehouse,
      'forbidden_role' => InviteErrorCode.forbiddenRole,
      'rate_limited' => InviteErrorCode.rateLimited,
      'invalid_token' => InviteErrorCode.invalidToken,
      'expired' => InviteErrorCode.expired,
      'revoked' => InviteErrorCode.revoked,
      'already_used' => InviteErrorCode.alreadyUsed,
      'email_mismatch' => InviteErrorCode.emailMismatch,
      'internal' => InviteErrorCode.internal,
      _ => null,
    };
  }
}

/// Result wrapper for every Edge-Function call.
sealed class InviteApiResult<T> {
  const InviteApiResult();
}

class InviteApiOk<T> extends InviteApiResult<T> {
  final T data;
  const InviteApiOk(this.data);
}

class InviteApiErr<T> extends InviteApiResult<T> {
  final InviteErrorCode code;
  final String message;
  final Map<String, dynamic>? details;
  const InviteApiErr(this.code, this.message, [this.details]);
}

class InviteApiService {
  final SupabaseClient _supabase;

  InviteApiService(this._supabase);

  /// Generic invoker that maps both successful and error responses onto
  /// `InviteApiResult`. Handles both transport models supabase_flutter has
  /// shipped: throwing FunctionException on non-2xx (older), or returning
  /// FunctionResponse with status set (newer).
  Future<InviteApiResult<Map<String, dynamic>>> _invoke(
    String fn,
    Map<String, dynamic> body,
  ) async {
    try {
      final res = await _supabase.functions.invoke(fn, body: body);
      return _interpret(res.status, res.data);
    } on FunctionException catch (e) {
      return _interpret(e.status, e.details);
    } on SocketException catch (e, st) {
      AppLogger.error('Invite Edge Function $fn: socket error', e, st);
      return InviteApiErr(
        InviteErrorCode.networkError,
        InviteErrorCode.networkError.defaultMessage,
      );
    } on TimeoutException catch (e, st) {
      AppLogger.error('Invite Edge Function $fn: timeout', e, st);
      return InviteApiErr(
        InviteErrorCode.networkError,
        InviteErrorCode.networkError.defaultMessage,
      );
    } catch (e, st) {
      AppLogger.error('Invite Edge Function $fn: unexpected error', e, st);
      return InviteApiErr(
        InviteErrorCode.internal,
        InviteErrorCode.internal.defaultMessage,
        {'exception': e.toString()},
      );
    }
  }

  InviteApiResult<Map<String, dynamic>> _interpret(int status, dynamic data) {
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      if (map['ok'] == true && status >= 200 && status < 300) {
        return InviteApiOk(map);
      }
      final wireCode = map['error']?.toString();
      final code = InviteErrorCode.fromWire(wireCode) ??
          InviteErrorCode.internal;
      final message = map['message']?.toString() ?? code.defaultMessage;
      final details = map['details'] is Map
          ? Map<String, dynamic>.from(map['details'] as Map)
          : null;
      return InviteApiErr(code, message, details);
    }
    return InviteApiErr(
      InviteErrorCode.internal,
      InviteErrorCode.internal.defaultMessage,
    );
  }

  // ── Step-1 modal validation ────────────────────────────────────────────
  Future<InviteApiResult<Map<String, dynamic>>> checkEmail(String email) {
    return _invoke('check-invite-email', {'email': email});
  }

  // ── Step-2 modal: create the invite, returns deep-link URL for share ───
  // Phase 2: optionally accepts a phone number; when present, the Edge
  // Function dispatches an SMS in addition to the email. Response shape
  // includes `human_code` (6-char), `email_sent`, `sms_sent`.
  Future<InviteApiResult<Map<String, dynamic>>> sendInvite({
    required String email,
    required String role,
    String? warehouseId,
    String? phone,
  }) {
    return _invoke('send-invite', {
      'email': email,
      'role': role,
      'warehouse_id': warehouseId,
      'phone': phone,
    });
  }

  // ── Resend an existing invite (revokes old + issues fresh) ─────────────
  Future<InviteApiResult<Map<String, dynamic>>> resendInvite(String inviteId) {
    return _invoke('resend-invite', {'invite_id': inviteId});
  }

  // ── Preview before redemption (deep-link landing screen) ───────────────
  Future<InviteApiResult<Map<String, dynamic>>> previewByToken(String token) {
    return _invoke('accept-invite', {'token': token});
  }

  Future<InviteApiResult<Map<String, dynamic>>> previewByCode(String code) {
    return _invoke('accept-invite', {'code': code});
  }

  // 6-char human_code preview (Phase 2). Distinct from the 8-char `code`.
  Future<InviteApiResult<Map<String, dynamic>>> previewByHumanCode(
    String humanCode,
  ) {
    return _invoke('accept-invite', {'human_code': humanCode});
  }

  // ── Atomic finalisation (creates user + business_members, marks invite
  //    accepted). Returns canonical {user, membership, invite} which the
  //    InviteLandingScreen routes through SyncService._applyDomainResponse.
  Future<InviteApiResult<Map<String, dynamic>>> redeemByToken({
    required String token,
    required String userName,
  }) {
    return _invoke('redeem-invite', {
      'token': token,
      'user_name': userName,
    });
  }

  Future<InviteApiResult<Map<String, dynamic>>> redeemByCode({
    required String code,
    required String userName,
  }) {
    return _invoke('redeem-invite', {
      'code': code,
      'user_name': userName,
    });
  }

  Future<InviteApiResult<Map<String, dynamic>>> redeemByHumanCode({
    required String humanCode,
    required String userName,
  }) {
    return _invoke('redeem-invite', {
      'human_code': humanCode,
      'user_name': userName,
    });
  }

  // ── Cancel a pending invite. Wraps the revoke-invite Edge Function which
  //    validates role_tier ≥ 4, guards against revoking accepted invites
  //    (`already_used`), is idempotent on already-revoked rows, and writes
  //    an `invite.revoked` activity_logs entry. Returns the updated row.
  Future<InviteApiResult<Map<String, dynamic>>> revokeInvite(String inviteId) {
    return _invoke('revoke-invite', {'invite_id': inviteId});
  }

  /// Direct UPDATE — RLS policy `invites_inviter_revoke` allows it for any
  /// caller in the same business. Superseded by [revokeInvite]; remaining
  /// call sites migrate in the staff-list rewrite, after which this can
  /// be deleted.
  Future<bool> revoke(String inviteId) async {
    try {
      await _supabase.from('invites').update({
        'status': 'revoked',
        'last_updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', inviteId);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Typed wrapper over the JSONB returned by accept_invite_preview.
/// Keep parsing tolerant — the RPC may add fields in future migrations
/// and we don't want to break older clients.
class InvitePreview {
  final String inviteId;
  final String businessId;
  final String businessName;
  final String role;
  final String? warehouseId;
  final String? warehouseName;
  final String email;
  final DateTime expiresAt;
  final String inviterName;

  const InvitePreview({
    required this.inviteId,
    required this.businessId,
    required this.businessName,
    required this.role,
    required this.warehouseId,
    required this.warehouseName,
    required this.email,
    required this.expiresAt,
    required this.inviterName,
  });

  factory InvitePreview.fromMap(Map<String, dynamic> map) {
    return InvitePreview(
      inviteId: map['invite_id']?.toString() ?? '',
      businessId: map['business_id']?.toString() ?? '',
      businessName: map['business_name']?.toString() ?? 'Unknown Business',
      role: map['role']?.toString() ?? 'staff',
      warehouseId: map['warehouse_id']?.toString(),
      warehouseName: map['warehouse_name']?.toString(),
      email: map['email']?.toString() ?? '',
      expiresAt: DateTime.tryParse(map['expires_at']?.toString() ?? '') ??
          DateTime.now().add(const Duration(hours: 48)),
      inviterName: map['inviter_name']?.toString() ?? 'your manager',
    );
  }
}


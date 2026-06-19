import 'package:flutter/material.dart';

// ═══════════════════════════════════════════════════════════════════════════
// BLUE CLASSIC PALETTE (original)
// ═══════════════════════════════════════════════════════════════════════════

// Light Theme
const Color lBg = Color(0xFFF8FAFC);
const Color lSurface = Color(0xFFFFFFFF);
const Color lCard = Color(0xFFF1F5F9);
const Color lText = Color(0xFF0F172A);
const Color lSubtext = Color(0xFF64748B);
const Color lBorder = Color(0xFFE2E8F0);

// Dark Theme
const Color dBg = Color(0xFF090D14);
const Color dSurface = Color(0xFF111827);
const Color dCard = Color(0xFF1C2438);
const Color dText = Color(0xFFF8FAFC);
const Color dSubtext = Color(0xFFA0AEC0);
const Color dBorder = Color(0x1EFFFFFF);

// Accents
const Color blueMain = Color(0xFF2563EB);
const Color bluePrimaryDark = Color(0xFF3B82F6); // High contrast blue for dark theme
const Color blueLight = Color(0xFF60A5FA);
const Color blueDark = Color(0xFF1D4ED8);
const Color danger = Color(0xFFEF4444);
const Color success = Color(0xFF10B981);

// ═══════════════════════════════════════════════════════════════════════════
// AMBER RIBAPLUS PALETTE (new)
// ═══════════════════════════════════════════════════════════════════════════

// Brand Colors (shared across light & dark)
const Color amberPrimary = Color(0xFFF5A623);
const Color amberPrimaryDark = Color(
  0xFFD97706,
); // Darker amber for better contrast on white
const Color contrastAmber = Color(
  0xFFD97706,
); // Specifically for light theme high-contrast elements
const Color amberDark = Color(0xFFFF7A00);
const Color amberGlow = Color(0x59F5A623); // rgba(245,166,35,0.35)
const Color dangerRed = Color(0xFFFF3B30);
const Color successGreen = Color(0xFF30D158);

// Amber Dark Theme
const Color adBg = Color(0xFF080C12);
const Color adSurface = Color(0xFF0E1420);
const Color adSurface2 = Color(0xFF141B28);
const Color adBorder = Color(0x0FFFFFFF); // rgba(255,255,255,0.06)
const Color adTextPrimary = Color(0xFFE8EEF6);
const Color adTextSecondary = Color(0xFF6B7A90);

// Amber Light Theme
const Color alBg = Color(0xFFF4F6FA);
const Color alSurface = Color(0xFFFFFFFF);
const Color alSurface2 = Color(0xFFEDF0F5);
const Color alBorder = Color(0x12000000); // rgba(0,0,0,0.07)
const Color alTextPrimary = Color(0xFF0E1420);
const Color alTextSecondary = Color(
  0xFF4B5563,
); // Darkened for better contrast (was 7A8899)
// ═══════════════════════════════════════════════════════════════════════════
// PURPLE VIOLET PALETTE (new)
// ═══════════════════════════════════════════════════════════════════════════

// Brand Colors (refined violet; light uses the deeper 7C3AED for contrast)
const Color purplePrimary = Color(0xFF8B5CF6); // dark-theme primary
const Color purplePrimaryDark = Color(0xFF7C3AED); // light-theme primary
const Color purpleDark = Color(0xFF6D28D9); // secondary / gradient end
const Color purpleGlow = Color(0x598B5CF6);

// Purple Dark Theme — NEUTRAL surfaces (no purple tint)
const Color pdBg = Color(0xFF0B0D10);
const Color pdSurface = Color(0xFF15171B);
const Color pdSurface2 = Color(0xFF1E2127);
const Color pdBorder = Color(0x14FFFFFF);
const Color pdTextPrimary = Color(0xFFF3F4F6);
const Color pdTextSecondary = Color(0xFF9CA3AF);

// Purple Light Theme — NEUTRAL surfaces (no purple tint)
const Color plBg = Color(0xFFF7F8FA);
const Color plSurface = Color(0xFFFFFFFF);
const Color plSurface2 = Color(0xFFEDF0F4);
const Color plBorder = Color(0x12000000);
const Color plTextPrimary = Color(0xFF111827);
const Color plTextSecondary = Color(0xFF6B7280);

// ═══════════════════════════════════════════════════════════════════════════
// GREEN FOREST PALETTE (new)
// ═══════════════════════════════════════════════════════════════════════════

// Brand Colors (darker, less neon than the old emerald)
const Color greenPrimary = Color(0xFF22C55E); // dark-theme primary
const Color greenContrast = Color(
  0xFF15803D,
); // light-theme primary (deep forest)
const Color greenPrimaryDark = Color(
  0xFF15803D,
); // light selectedItem / chip-selected
const Color greenDark = Color(0xFF166534); // secondary / gradient end
const Color greenGlow = Color(0x5922C55E);

// Green Dark Theme — NEUTRAL surfaces (no green tint)
const Color gdBg = Color(0xFF0B0D10);
const Color gdSurface = Color(0xFF15171B);
const Color gdSurface2 = Color(0xFF1E2127);
const Color gdBorder = Color(0x14FFFFFF);
const Color gdTextPrimary = Color(0xFFF3F4F6);
const Color gdTextSecondary = Color(0xFF9CA3AF);

// Green Light Theme — NEUTRAL surfaces (no green tint)
const Color glBg = Color(0xFFF7F8FA);
const Color glSurface = Color(0xFFFFFFFF);
const Color glSurface2 = Color(0xFFEDF0F4);
const Color glBorder = Color(0x12000000);
const Color glTextPrimary = Color(0xFF111827);
const Color glTextSecondary = Color(0xFF6B7280);

// ═══════════════════════════════════════════════════════════════════════════
// BLACK & WHITE PALETTE (monochrome chrome; status colours stay coloured)
// ═══════════════════════════════════════════════════════════════════════════

// B&W Light Theme
const Color bwlBg = Color(0xFFF4F4F5);
const Color bwlSurface = Color(0xFFFFFFFF);
const Color bwlSurface2 = Color(0xFFE7E7E9);
const Color bwlBorder = Color(0x14000000);
const Color bwlTextPrimary = Color(0xFF09090B);
const Color bwlTextSecondary = Color(0xFF52525B);
const Color bwPrimaryLight = Color(0xFF111111); // near-black primary
const Color bwSecondaryLight = Color(0xFF3F3F46); // gradient end (black→gray)

// B&W Dark Theme
const Color bwdBg = Color(0xFF000000);
const Color bwdSurface = Color(0xFF121212);
const Color bwdSurface2 = Color(0xFF1E1E1E);
const Color bwdBorder = Color(0x1FFFFFFF);
const Color bwdTextPrimary = Color(0xFFFAFAFA);
const Color bwdTextSecondary = Color(0xFFA1A1AA);
const Color bwPrimaryDark = Color(0xFFFAFAFA); // near-white primary
const Color bwSecondaryDark = Color(0xFFBDBDBD); // gradient end (white→gray)

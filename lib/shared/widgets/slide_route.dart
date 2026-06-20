import 'package:flutter/material.dart';

const _kForward = Duration(milliseconds: 500);
const _kReverse = Duration(milliseconds: 280);
const _kCurve = Curves.fastOutSlowIn;

// NOTE: these intentionally do NOT cross-fade the page opacity. The incoming
// screens are full-screen and opaque (their root gradient's first stop is the
// opaque scaffoldBackgroundColor), and the outgoing screen underneath stays
// fully opaque during the push. Fading the incoming page's opacity from 0→1
// over an opaque page blends BOTH screens mid-transition, leaving a ghost of
// the previous screen's text (the "glitchy leftover text" bug). A slide of an
// opaque page fully covers what's underneath, so we slide only.
Route<T> slideDownRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: _kForward,
    reverseTransitionDuration: _kReverse,
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, animation, __, child) {
      final curved = CurvedAnimation(parent: animation, curve: _kCurve);
      final offset = Tween<Offset>(
        begin: const Offset(0, -1),
        end: Offset.zero,
      ).animate(curved);
      return SlideTransition(position: offset, child: child);
    },
  );
}

Route<T> slideLeftRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: _kForward,
    reverseTransitionDuration: _kReverse,
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, animation, __, child) {
      final curved = CurvedAnimation(parent: animation, curve: _kCurve);
      final offset = Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(curved);
      return SlideTransition(position: offset, child: child);
    },
  );
}

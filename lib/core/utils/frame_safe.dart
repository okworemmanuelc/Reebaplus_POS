import 'package:flutter/scheduler.dart';

/// Whether the framework is mid-frame, where notifying listeners is unsafe.
///
/// During `persistentCallbacks` (build/layout/paint) and the microtasks that
/// run inside it, marking a widget dirty is only legal if that widget is an
/// ancestor of the one currently building. Anything reached through a shared
/// notifier — a sibling `ListenableBuilder`, an overlay in a parent `Stack` —
/// is not, and Flutter rejects it outright with "setState() or
/// markNeedsBuild() called during build".
bool isFrameLocked() {
  try {
    final phase = SchedulerBinding.instance.schedulerPhase;
    return phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks;
  } catch (_) {
    // No binding (pure unit test) — nothing can be mid-build.
    return false;
  }
}

/// Runs [action] now, or at the end of the current frame if one is in flight.
///
/// Use this for any write to a notifier that widgets outside the caller's own
/// subtree listen to, when the write can originate from `initState`, `dispose`
/// or a layout callback. A post-frame callback does not itself request a
/// frame, so deferring costs nothing once the app is idle.
void frameSafe(VoidCallback action) {
  if (!isFrameLocked()) {
    action();
    return;
  }
  SchedulerBinding.instance.addPostFrameCallback((_) => action());
}

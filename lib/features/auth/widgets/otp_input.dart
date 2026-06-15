import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Six styled OTP boxes driven by a single hidden TextField.
class OtpBoxRow extends StatefulWidget {
  final TextEditingController controller;
  final bool hasError;
  final VoidCallback? onSubmit;
  final bool ignorePointers;
  final bool readOnly;
  final Color textColor;
  final ValueChanged<String>? onChanged;

  const OtpBoxRow({
    super.key,
    required this.controller,
    required this.hasError,
    this.onSubmit,
    this.ignorePointers = false,
    this.readOnly = false,
    this.onChanged,
    required this.textColor,
  });

  @override
  State<OtpBoxRow> createState() => _OtpBoxRowState();
}

class _OtpBoxRowState extends State<OtpBoxRow> with WidgetsBindingObserver {
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted && !widget.ignorePointers && !_focusNode.hasFocus) {
        _requestKeyboard();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The platform tears down the input connection on app-switch. On
      // return, the FocusNode may still think it has focus but no keyboard
      // is visible. Wait for the engine to settle, then re-request.
      Future.delayed(const Duration(milliseconds: 400), () {
        if (!mounted || widget.ignorePointers) return;
        _requestKeyboard();
      });
    }
  }

  /// Safely requests focus and shows the keyboard.
  ///
  /// If the node already has focus, we schedule an unfocus + refocus on the
  /// next frame to force a new platform input connection. All operations
  /// are guarded by [mounted] checks to avoid use-after-dispose crashes.
  void _requestKeyboard() {
    if (!mounted) return;

    if (_focusNode.hasFocus) {
      // Node thinks it has focus but keyboard may be gone. Unfocus on this
      // frame, then refocus on the next frame to force a new connection.
      _focusNode.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.ignorePointers) return;
        _focusNode.requestFocus();
        SystemChannels.textInput.invokeMethod('TextInput.show');
      });
    } else {
      _focusNode.requestFocus();
      SystemChannels.textInput.invokeMethod('TextInput.show');
    }
  }

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (!widget.ignorePointers) {
          _requestKeyboard();
        }
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: Opacity(
              opacity: 0,
              child: TextField(
                controller: widget.controller,
                focusNode: _focusNode,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textInputAction: TextInputAction.done,
                onChanged: widget.onChanged,
                onSubmitted: (_) => widget.onSubmit?.call(),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                autofocus: false,
                readOnly: widget.readOnly,
                decoration: const InputDecoration(counterText: ''),
              ),
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 8.0;
              final boxSize = ((constraints.maxWidth - gap * 5) / 6).clamp(
                0.0,
                46.0,
              );
              final boxHeight = boxSize * (56 / 46);
              return ListenableBuilder(
                listenable: widget.controller,
                builder: (_, __) {
                  final text = widget.controller.text;
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(6, (i) {
                      final filled = i < text.length;
                      final digit = filled ? text[i] : '';
                      final isActive = i == text.length && _focusNode.hasFocus;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        margin: EdgeInsets.only(right: i < 5 ? gap : 0),
                        width: boxSize,
                        height: boxHeight,
                        decoration: BoxDecoration(
                          color: filled
                              ? widget.textColor.withValues(alpha: 0.18)
                              : widget.textColor.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: widget.hasError
                                ? errorColor
                                : isActive
                                    ? widget.textColor
                                    : widget.textColor
                                          .withValues(alpha: 0.3),
                            width: isActive ? 2 : 1,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            digit,
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: widget.textColor,
                            ),
                          ),
                        ),
                      );
                    }),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

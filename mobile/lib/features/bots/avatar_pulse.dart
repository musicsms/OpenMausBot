import 'package:flutter/material.dart';
import '../../core/theme/grok_theme.dart';

class AvatarPulse extends StatefulWidget {
  final bool isThinking;
  final double size;
  final String? imagePath;

  const AvatarPulse({
    super.key,
    this.isThinking = false,
    this.size = 48.0,
    this.imagePath,
  });

  @override
  State<AvatarPulse> createState() => _AvatarPulseState();
}

class _AvatarPulseState extends State<AvatarPulse> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _opacityAnimation = Tween<double>(begin: 0.6, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    if (widget.isThinking) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(AvatarPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isThinking != oldWidget.isThinking) {
      if (widget.isThinking) {
        _controller.repeat(reverse: true);
      } else {
        _controller.stop();
        _controller.reset();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: widget.size * 1.3,
        height: widget.size * 1.3,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (widget.isThinking)
              AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return Transform.scale(
                    scale: _scaleAnimation.value,
                    child: Container(
                      width: widget.size,
                      height: widget.size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: GrokTheme.glowCyan.withOpacity(_opacityAnimation.value),
                      ),
                    ),
                  );
                },
              ),
            Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: GrokTheme.darkCharcoal,
                border: Border.all(
                  color: widget.isThinking ? GrokTheme.glowCyan : GrokTheme.slateBorder,
                  width: 1.5,
                ),
              ),
              child: widget.imagePath != null && widget.imagePath!.isNotEmpty
                  ? ClipOval(
                      child: Image.asset(
                        widget.imagePath!,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            Icon(Icons.smart_toy_outlined, color: Colors.white, size: widget.size * 0.5),
                      ),
                    )
                  : Icon(Icons.smart_toy_outlined, color: Colors.white, size: widget.size * 0.5),
            ),
          ],
        ),
      ),
    );
  }
}

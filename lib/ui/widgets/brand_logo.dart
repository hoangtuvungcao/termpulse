import 'package:flutter/material.dart';
import 'package:termpulse/core/theme.dart';

class TermPulseLogo extends StatelessWidget {
  final double size;
  final bool showGlow;

  const TermPulseLogo({super.key, this.size = 36, this.showGlow = true});

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.24),
        border: Border.all(
          color: tp.borderStrong.withValues(alpha: 0.55),
          width: 0.8,
        ),
        boxShadow: showGlow
            ? [
                BoxShadow(
                  color: tp.accent.withValues(alpha: 0.22),
                  blurRadius: size * 0.42,
                  spreadRadius: -size * 0.08,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.asset(
          'assets/branding/termpulse_icon.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }
}

class TermPulseWordmark extends StatelessWidget {
  final double iconSize;
  final double fontSize;
  final bool showTag;

  const TermPulseWordmark({
    super.key,
    this.iconSize = 26,
    this.fontSize = 15.5,
    this.showTag = false,
  });

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TermPulseLogo(size: iconSize, showGlow: showTag),
        SizedBox(width: iconSize * 0.3),
        RichText(
          text: TextSpan(
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.35,
            ),
            children: [
              TextSpan(
                text: 'Term',
                style: TextStyle(color: tp.ink),
              ),
              TextSpan(
                text: 'Pulse',
                style: TextStyle(color: tp.accent),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

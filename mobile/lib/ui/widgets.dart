import 'package:flutter/material.dart';

import 'theme.dart';

/// Shared presentational widgets.

class WdCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? borderColor;
  final VoidCallback? onTap;

  const WdCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WeDropColors.surface.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor ?? WeDropColors.border),
          ),
          child: child,
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? hint;
  final Widget? trailing;

  const SectionHeader({super.key, required this.title, this.hint, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: WeDropColors.ink,
                    letterSpacing: -0.2,
                  ),
                ),
                if (hint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      hint!,
                      style: const TextStyle(fontSize: 12.5, color: WeDropColors.inkFaint),
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  /// One of: connected, online, offline.
  final String state;

  const StatusDot(this.state, {super.key});

  @override
  Widget build(BuildContext context) {
    final colour = switch (state) {
      'connected' => WeDropColors.success,
      'online' => WeDropColors.warn,
      _ => WeDropColors.inkFaint.withValues(alpha: 0.6),
    };

    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: colour,
        shape: BoxShape.circle,
        boxShadow: state == 'connected'
            ? [BoxShadow(color: colour.withValues(alpha: 0.55), blurRadius: 8, spreadRadius: 1)]
            : null,
      ),
    );
  }
}

class WdBadge extends StatelessWidget {
  final String label;
  final Color colour;

  const WdBadge(this.label, {super.key, this.colour = WeDropColors.brandSoft});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: colour),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String hint;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.hint,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 44),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: WeDropColors.border, style: BorderStyle.solid),
      ),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: WeDropColors.surfaceHi,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: WeDropColors.inkFaint, size: 22),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: WeDropColors.inkDim,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, color: WeDropColors.inkFaint, height: 1.45),
          ),
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    );
  }
}

class SettingTile extends StatelessWidget {
  final String title;
  final String? description;
  final Widget control;
  final bool last;

  const SettingTile({
    super.key,
    required this.title,
    this.description,
    required this.control,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        border: last
            ? null
            : const Border(bottom: BorderSide(color: WeDropColors.border, width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: WeDropColors.ink,
                  ),
                ),
                if (description != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3, right: 12),
                    child: Text(
                      description!,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: WeDropColors.inkFaint,
                        height: 1.4,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          control,
        ],
      ),
    );
  }
}

/// The six digits shown on both devices while pairing.
class VerificationCodeDisplay extends StatelessWidget {
  final String code;

  const VerificationCodeDisplay(this.code, {super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Text(
          'VERIFICATION CODE',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1.6,
            fontWeight: FontWeight.w600,
            color: WeDropColors.inkFaint,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: code.split('').map((digit) {
            return Container(
              width: 38,
              height: 46,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: WeDropColors.bgSoft,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: WeDropColors.borderHi),
              ),
              child: Text(
                digit,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: WeDropColors.brandSoft,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        const Text(
          'Only continue if the other device shows these same digits.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: WeDropColors.inkFaint, height: 1.4),
        ),
      ],
    );
  }
}

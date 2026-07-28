import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Shared presentational widgets.

/// A small, rounded album-art preview decoded from a base64 JPEG. Falls back
/// to a generic note icon if the bytes ever fail to decode (a partial/corrupt
/// transfer should never crash a screen).
class ArtworkThumbnail extends StatefulWidget {
  final String base64;
  final double size;
  final double radius;

  const ArtworkThumbnail({super.key, required this.base64, this.size = 52, this.radius = 10});

  @override
  State<ArtworkThumbnail> createState() => _ArtworkThumbnailState();
}

class _ArtworkThumbnailState extends State<ArtworkThumbnail> {
  Uint8List? _bytes;
  String? _decodedFor;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(ArtworkThumbnail old) {
    super.didUpdateWidget(old);
    _decode();
  }

  // Whatever embeds this (the media cards) rebuilds far more often than the
  // artwork itself changes — MediaState ticks every second or so just to
  // interpolate the progress bar. Re-decoding the same base64 string on every
  // one of those rebuilds handed Image.memory a brand-new Uint8List each
  // time; since MemoryImage's equality compares that list by reference, the
  // framework could never recognize two decodes of the same artwork as "the
  // same image" and redecoded (and repainted) it on every tick — the visible
  // flicker, and the HWUI "Image decoding logging dropped!" spam from
  // decoding far more often than anything actually changed. Skipping the
  // decode whenever the base64 string itself hasn't changed keeps the same
  // Uint8List (and so the same resolved image) across all those rebuilds.
  void _decode() {
    if (_decodedFor == widget.base64) return;
    _decodedFor = widget.base64;
    try {
      _bytes = base64Decode(widget.base64);
    } catch (_) {
      _bytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: WeDropColors.surfaceHi,
      child: Icon(Icons.music_note_rounded, color: WeDropColors.inkFaint, size: widget.size * 0.45),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: _bytes == null
            ? fallback
            : Image.memory(
                _bytes!,
                fit: BoxFit.cover,
                // Keeps showing the previous frame instead of flashing blank
                // for the rare case the artwork genuinely does change.
                gaplessPlayback: true,
                errorBuilder: (context, error, stack) => fallback,
              ),
      ),
    );
  }
}

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

/// The small uppercase heading that labels a group *inside* a [WdCard].
///
/// Distinct from [SectionHeader], which titles a whole page section at a
/// larger size — using that one inside a card makes the card's own label
/// compete with the screen title for attention.
class CardLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const CardLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Row(
        children: [
          Expanded(child: Text(text.toUpperCase(), style: AppText.eyebrow)),
          ?trailing,
        ],
      ),
    );
  }
}

/// A tappable tile with an icon over a label — the shape used for every
/// mouse-click, scroll and presentation control.
///
/// This exists because those controls had drifted into five near-identical
/// private builders, each with its own height, radius and colour; one
/// primitive with an [active] state keeps them visually identical and makes
/// a toggle (the laser pointer) just another instance rather than a sixth
/// variant.
class WdActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Renders the tile in its "on" state, for controls that toggle.
  final bool active;

  /// Taller, for primary controls that sit alone in a row.
  final bool prominent;

  const WdActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.prominent = false,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = active ? WeDropColors.brandSoft : WeDropColors.inkDim;

    return Material(
      color: active
          ? WeDropColors.brand.withValues(alpha: 0.16)
          : WeDropColors.surfaceHi,
      borderRadius: BorderRadius.circular(Radii.control),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.control),
        child: Container(
          height: prominent ? 60 : 52,
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: prominent ? 22 : 18, color: foreground),
              const SizedBox(height: Space.xs),
              Text(label, style: AppText.caption.copyWith(color: foreground)),
            ],
          ),
        ),
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
        Builder(
          builder: (context) {
            // Sized from the screen width rather than a LayoutBuilder: this
            // widget is also used inside an AlertDialog, which measures its
            // content with intrinsic-width sizing — LayoutBuilder cannot be
            // used under intrinsic sizing (it throws at layout time), which
            // silently broke the whole dialog and left only its dim barrier
            // visible with no visible content at all.
            final digits = code.split('');
            final screenWidth = MediaQuery.sizeOf(context).width;
            // A generous estimate of the chrome around this widget (dialog/
            // overlay padding and margins) so the tiles fit comfortably
            // without needing this widget's actual incoming constraints —
            // this is only ever approximate (different callers wrap it in
            // different padding), so the scroll view below is the actual
            // guarantee against overflow, not this number.
            final available = screenWidth - 120;
            final tileWidth = (available / digits.length).clamp(26.0, 36.0);
            final row = Row(
              mainAxisSize: MainAxisSize.min,
              children: digits.map((digit) {
                return Container(
                  width: tileWidth,
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
            );
            // However close the estimate above gets, this is what actually
            // prevents a RenderFlex overflow: if the tiles are even a few
            // pixels wider than the space this particular caller grants,
            // this scrolls instead of clipping/overflowing.
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: row,
            );
          },
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

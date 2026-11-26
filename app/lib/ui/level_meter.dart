import 'dart:async';

import 'package:flutter/material.dart';

import '../services/tx_level.dart';
import 'theme.dart';

/// One level row: label, a smooth capsule bar with a peak-hold mark, and the
/// peak in dB. Falls back slowly so speech reads calmly; the mark keeps the
/// last peak for two seconds.
class LevelBar extends StatefulWidget {
  const LevelBar({super.key, required this.label, required this.meter, this.compact = false});
  final String label;
  final LevelMeter meter;

  /// Narrow form for two bars side by side: the value without its unit.
  final bool compact;

  /// The bar spans this range below full scale.
  static const rangeDb = 48.0;

  @override
  State<LevelBar> createState() => _LevelBarState();
}

class _LevelBarState extends State<LevelBar> {
  static const _tick = Duration(milliseconds: 50);
  static const _fallPerTick = 1.5; // 30 dB per second
  static const _hold = Duration(seconds: 2);

  Timer? _t;
  double _bar = LevelMeter.floorDb;
  double _peak = LevelMeter.floorDb;
  DateTime _peakAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(_tick, (_) => _step());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  void _step() {
    final now = DateTime.now();
    final v = widget.meter.db;
    var bar = v > _bar ? v : (_bar - _fallPerTick).clamp(LevelMeter.floorDb, 0.0);
    if (bar < v) bar = v;
    var peak = _peak, peakAt = _peakAt;
    if (v >= peak) {
      peak = v;
      peakAt = now;
    } else if (now.difference(peakAt) > _hold) {
      peak = bar;
      peakAt = now;
    }
    // Idle: nothing changes, so no frame is scheduled.
    if (bar == _bar && peak == _peak) return;
    setState(() {
      _bar = bar;
      _peak = peak;
      _peakAt = peakAt;
    });
  }

  static double _pos(double db) => ((db + LevelBar.rangeDb) / LevelBar.rangeDb).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final silent = _peak <= -LevelBar.rangeDb;
    final mark = _peak > -3 ? Tokens.emergency : (_peak > -9 ? Tokens.connecting : scheme.primary);
    final caption = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]);
    return Semantics(
      label: '${widget.label} level',
      value: silent ? 'silent' : '${_peak.round()} dB',
      child: ExcludeSemantics(
        child: Row(children: [
          SizedBox(width: widget.compact ? 21 : 26, child: Text(widget.label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant))),
          Expanded(
            child: SizedBox(
              height: 14,
              child: LayoutBuilder(builder: (context, c) {
                final w = c.maxWidth;
                return Stack(alignment: Alignment.centerLeft, children: [
                  Container(height: 8, decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(4))),
                  Container(width: w * _pos(_bar), height: 8, decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(4))),
                  if (!silent)
                    Positioned(
                      left: (w * _pos(_peak) - 3).clamp(0.0, w - 3),
                      child: Container(width: 3, height: 14, decoration: BoxDecoration(color: mark, borderRadius: BorderRadius.circular(2))),
                    ),
                ]);
              }),
            ),
          ),
          SizedBox(
            width: widget.compact ? 28 : 52,
            child: Text('${silent ? '-∞' : _peak.round()}${widget.compact ? '' : ' dB'}', textAlign: TextAlign.right, style: caption),
          ),
        ]),
      ),
    );
  }
}

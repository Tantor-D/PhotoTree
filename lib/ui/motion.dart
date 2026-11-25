import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// App-owned drag and return rules. Flutter supplies input, frames and drawing;
/// this component contains no Android or device-brand behavior.
class DragSpring extends StatefulWidget {
  const DragSpring({
    required this.child,
    this.maxOffset = const Offset(96, 96),
    this.spring = const SpringDescription(mass: 1, stiffness: 180, damping: 28),
    super.key,
  });

  final Widget child;
  final Offset maxOffset;
  final SpringDescription spring;

  @override
  State<DragSpring> createState() => _DragSpringState();
}

class _DragSpringState extends State<DragSpring>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _x;
  late final AnimationController _y;
  late final Listenable _position;
  bool _acceptInput = true;

  @override
  void initState() {
    super.initState();
    _x = AnimationController.unbounded(vsync: this);
    _y = AnimationController.unbounded(vsync: this);
    _position = Listenable.merge([_x, _y]);
    WidgetsBinding.instance.addObserver(this);
  }

  void _stop() {
    _x.stop();
    _y.stop();
  }

  void _drag(DragUpdateDetails details) {
    if (!_acceptInput) return;
    _x.value = (_x.value + details.delta.dx)
        .clamp(-widget.maxOffset.dx, widget.maxOffset.dx)
        .toDouble();
    _y.value = (_y.value + details.delta.dy)
        .clamp(-widget.maxOffset.dy, widget.maxOffset.dy)
        .toDouble();
  }

  void _returnToOrigin() {
    if (!_acceptInput) return;
    // Return from the displayed position. A fresh touch stops both simulations
    // before any drag threshold, so taking over never resets to the origin.
    // The sample deliberately returns without adding fling momentum.
    if (_x.value != 0) {
      _x.animateWith(SpringSimulation(widget.spring, _x.value, 0, 0));
    }
    if (_y.value != 0) {
      _y.animateWith(SpringSimulation(widget.spring, _y.value, 0, 0));
    }
  }

  @override
  void didUpdateWidget(DragSpring oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.maxOffset != oldWidget.maxOffset) {
      // A rotated or resized sample must remain reachable inside its surface.
      _stop();
      _x.value = _x.value
          .clamp(-widget.maxOffset.dx, widget.maxOffset.dx)
          .toDouble();
      _y.value = _y.value
          .clamp(-widget.maxOffset.dy, widget.maxOffset.dy)
          .toDouble();
      _returnToOrigin();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _acceptInput = state == AppLifecycleState.resumed;
    if (!_acceptInput) {
      _stop();
      _x.value = 0;
      _y.value = 0;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _x.dispose();
    _y.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AnimatedBuilder(
        animation: _position,
        builder: (context, child) => Transform.translate(
          offset: Offset(_x.value, _y.value),
          child: child,
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanDown: (_) => _stop(),
          onPanUpdate: _drag,
          onPanEnd: (_) => _returnToOrigin(),
          onPanCancel: _returnToOrigin,
          child: widget.child,
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:flutter_tvos/flutter_tvos.dart'
    show TvRemoteController, TvRemoteTouchEvent, TvRemoteTouchPhase;

import 'package:flutter/gestures.dart';

import '../../preference/preference_constants.dart'
    show SiriRemoteSwipeSensitivity;
import 'gamepad/gamepad_key_synthesizer.dart';

// TODO: remove these logging bits
import 'package:get_it/get_it.dart';
import '../../data/services/log_service.dart';
final log = GetIt.instance<LogService>();

// Turns Siri Remote touchpad gestures into focus navigation.
//
// Features:
// - Small movement is ignored
// - The dominant axis is locked once established
// - Movement is translated into a velocity (steps / s)
// - Steps will be emitted at the peak observed velocity until
//   the finger is lifted
// - If a gesture lasts longer than _holdThreshold
//   the movement stops at gesture end
// - If the gesture lasts shorter than _holdThreshold
//   the gesture registers as a "flick" and velocity decays
//   at _momentumDecay rate following an exponential decay
//
// Navigation is emitted as real arrow key events through
// [GamepadKeySynthesizer].

class SiriRemoteGlide {
  SiriRemoteGlide._();

  static final SiriRemoteGlide instance = SiriRemoteGlide._();
  final GamepadKeySynthesizer _synthesizer = GamepadKeySynthesizer();

  SiriRemoteSwipeSensitivity sensitivity =
      SiriRemoteSwipeSensitivity.medium;

  VelocityTracker _velocityTracker = VelocityTracker.withKind(PointerDeviceKind.trackpad);

  bool _attached = false;
  bool _touching = false;
  bool _held = false;
  bool? _isVertical = null;

  double? _peakVelocity = null;
  // Observed velocity is +/- 30 out of VelocityTracker
  // Need to normalize it to a min/max
  // +/- 0.5 -- treat as dead
  // >= abs(25) -- treat as max
  // min speed 1 step/s
  // max speed 10 step/s
  /*
      Observed velocity +/- 30 from VelocityTracker
      1. Clamp <= abs(0.5) to 0 (adjust for sensitivity)
      2. Clamp <= abs(25) to 10 (adjust for sensitivity)
      3. Consider max/min step/s (max is limited by _pollingRate)
      4. ** Could decouple pollingRate with a stepRate timer for finer granularity **
      5. peakVelocity could be named something else and be the number of ticks of the clock before firing a new step
  */

  GamepadNavKey? _direction;

  Timer? _pollTimer;
  Timer? _heldTimer;

  final Stopwatch _stopWatch = Stopwatch();


  // ---------------------------------------------------------------------------
  // Gesture tuning
  // ---------------------------------------------------------------------------

  // Polling rate; minimum step interval
  static const Duration _pollingRate = Duration(milliseconds:100);

  // Rate at which velocity of a flick decays.
  static const double _momentumDecay = 1.0;

  // Rate below which a gesture is ignored. (step/second)
  static const double _minStepRate = 1.0;

  // Rate below which a flick is considered stopped. (step/second)
  static const double _minFlickStepRate = 5.0;

  // Gesture duration before a flick becomes a glide.
  static const Duration _holdThreshold = Duration(milliseconds: 500);

  // Velocity smoothing factor
  static const double _smoothing = 0.20;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  void attach() {
    if (_attached) return;

    _attached = true;
    TvRemoteController.instance.addRawListener(_onTouch);
  }

  @visibleForTesting
  void debugReset() {
    _synthesizer.releaseAll();
    _stopPollTimer();
    _stopHeldTimer();

    _touching = false;
    _held = false;
    _isVertical = null;
    _direction = null;
    _peakVelocity = null;

    _stopWatch
        ..stop()
        ..reset();
  }

  @visibleForTesting
  void debugHandleTouch(TvRemoteTouchEvent event) => _onTouch(event);

  // ---------------------------------------------------------------------------
  // Touch handling
  // ---------------------------------------------------------------------------

  void _onTouch(TvRemoteTouchEvent event) {
    switch (event.phase) {
      case TvRemoteTouchPhase.started:
        _beginGesture(event.x, event.y);

      case TvRemoteTouchPhase.move:
        if (!_touching) {
          _beginGesture(event.x, event.y);
          return;
        }
        _onMove(event.x, event.y);

      case TvRemoteTouchPhase.ended:
      case TvRemoteTouchPhase.cancelled:
        _endGesture();

      case TvRemoteTouchPhase.loc:
      case TvRemoteTouchPhase.clickStart:
      case TvRemoteTouchPhase.clickEnd:
        break;
    }
  }

  void _beginGesture(double x, double y) {
    // Stop timers.
    _stopPollTimer();
    _stopHeldTimer();

    // Set initial gesture conditions.
    _touching = true;
    _held = false;
    _isVertical = null;
    _direction = null;
    _peakVelocity = null;
 
    // Start timing the gesture.
    _stopWatch
      ..reset()
      ..start();

    _velocityTracker = VelocityTracker.withKind(PointerDeviceKind.trackpad);
    _velocityTracker.addPosition(_stopWatch.elapsed, Offset(x, y));

    _startHeldTimer();
    _startPollTimer();
  }

  void _onMove(double x, double y) {
    _velocityTracker.addPosition(_stopWatch.elapsed, Offset(x, y));
  }

  // ---------------------------------------------------------------------------
  // Axis locking
  // ---------------------------------------------------------------------------

  void _updateAxis(double x, double y) {
    _isVertical = y.abs() > x.abs() ? true : false;
  }

  // ---------------------------------------------------------------------------
  // Direction
  // ---------------------------------------------------------------------------

  void _updateDirection(double dx, double dy) {
  }

  // ---------------------------------------------------------------------------
  // Navigation steps
  // ---------------------------------------------------------------------------

  void _startPollTimer() {
    if (_pollTimer != null) {
      return;
    }

    _pollTimer = Timer.periodic(
        _pollingRate,
        (_) {
          final velocity = _velocityTracker.getVelocityEstimate();
          if (velocity == null) return;

          final vx = velocity.pixelsPerSecond.dx;
          final vy = velocity.pixelsPerSecond.dy;
          final confidence = velocity.confidence;
          final duration = velocity.duration;

          log.playback(
            'vx is ${vx.toStringAsFixed(3)}\n'
            'vy is ${vy.toStringAsFixed(3)}\n'
            'confidence is ${confidence.toStringAsFixed(3)}\n'
            'duration is ${duration.inMilliseconds}ms\n'
          );
        },
    );
  }


  // ---------------------------------------------------------------------------
  // Gesture ending
  // ---------------------------------------------------------------------------

  void _endGesture() {
    if (!_touching) {
      return;
    }

    _touching = false;
    _held = false;
    _isVertical = null;
    _direction = null;

    _stopHeldTimer();
    _stopPollTimer();
    _stopWatch
        ..stop()
        ..reset();
  }

  // ---------------------------------------------------------------------------
  // Timer
  // ---------------------------------------------------------------------------

  void _stopPollTimer() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _stopHeldTimer() {
    _heldTimer?.cancel();
    _heldTimer = null;
  }

  void _startHeldTimer() {
    if (_heldTimer != null) {
      return;
    }
    _heldTimer = Timer(_holdThreshold, () {
      if (_touching) {
        _held = true;
      }
    });
  }

  double mapVelocity(
      double velocity, {
      required double minVelocity,
      required double maxVelocity,
      required double minStepRate,
      required double maxStepRate,
      }) {
    final v = velocity.clamp(-maxVelocity, maxVelocity);

    if (v.abs() < minVelocity) {
      return 0;
    }

    final magnitude = v.abs();

    final t = (magnitude - minVelocity) /
      (maxVelocity - minVelocity);

    final stepRate = minStepRate +
      t * (maxStepRate - minStepRate);

    return v.isNegative ? -stepRate : stepRate;
  }

}

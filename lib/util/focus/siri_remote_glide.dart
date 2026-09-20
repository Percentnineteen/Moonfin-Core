import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_tvos/flutter_tvos.dart'
    show TvRemoteController, TvRemoteTouchEvent, TvRemoteTouchPhase;

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
//   at _momentumDecay rate
//
// Navigation is emitted as real arrow key events through
// [GamepadKeySynthesizer].
class SiriRemoteGlide {
  SiriRemoteGlide._();

  static final SiriRemoteGlide instance = SiriRemoteGlide._();

  SiriRemoteSwipeSensitivity sensitivity =
      SiriRemoteSwipeSensitivity.medium;

  final GamepadKeySynthesizer _synthesizer = GamepadKeySynthesizer();

  bool _attached = false;
  bool _touching = false;
  bool _held = false;

  double _lastX = 0;
  double _lastY = 0;

  double _stepRate = 0;

  final Stopwatch _stopWatch = Stopwatch();

  // TODO: consider bool? horizontal;
  _Axis? _axis;
  GamepadNavKey? _direction;

  Timer? _stepTimer;
  Timer? _heldTimer;

  // ---------------------------------------------------------------------------
  // Gesture tuning
  // ---------------------------------------------------------------------------

  // Rate at which velocity of a flick decays.
  static const double _momentumDecay = 5.0;

  // Rate below which a gesture is ignored. (step/second)
  static const double _minStepRate = 0.75;

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
    _stopStepTimer();
    _stopHeldTimer();

    _touching = false;
    _held = false;
    _axis = null;
    _direction = null;

    _stepRate = 0;

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
    _stopStepTimer();
    _stopHeldTimer();

    // Set initial gesture conditions.
    _touching = true;
    _held = false;
    _lastX = x;
    _lastY = y;
    _stepRate = 0;
    _axis = null;
    _direction = null;
 
    // Start timing the gesture.
    _stopWatch
      ..reset()
      ..start();

    // TODO: make this a function
    _heldTimer = Timer(_holdThreshold, () {
      if (_touching) {
        _held = true;
      }
    });
  }

  void _onMove(double x, double y) {
    // The accumulated distance since the last processed movement.
    final dx = x - _lastX;
    final dy = y - _lastY;

    // Current time in seconds.
    final dt = _stopWatch.elapsedMicroseconds / 1000000.0;

    // log.playback(
    //     'dt=${dt.toStringAsFixed(3)} '
    //     'x=${x.toStringAsFixed(3)} '
    //     'y=${y.toStringAsFixed(3)} '
    //     'dx=${dx.toStringAsFixed(3)} '
    //     'dy=${dy.toStringAsFixed(3)} '
    //     );

    // TODO: should this be configurable? Slowest step
    // TODO: consider if this should return
    // if (dt <= 0 || dt > 0.25) {
    //   log.playback('rejected: out of range: ${dt.toStringAsFixed(3)}');
    //   return;
    // }

    _updateStepRate(dx, dy, dt);

    if (_axis != null && _direction != null && _stepRate >= _minStepRate) {
      _lastX = x;
      _lastY = y;
      _stopWatch.reset();
      _step(_direction!);
      _startStepTimer();
    }
  }

  // ---------------------------------------------------------------------------
  // Velocity
  // ---------------------------------------------------------------------------

  void _updateStepRate(double dx, double dy, double dt) {
    if (_axis == null) {
      _updateAxis(dx, dy);
    }
    final double dist = _axis == _Axis.horizontal ? dx.abs() : dy.abs();

    final threshold = _stepRate == 0
      ? sensitivity.firstStepTravel
      : sensitivity.stepTravel;
    if (dist < threshold) {
      // log.playback(
      // 'rejected: dist too small '
      // 'dist=${dist.toStringAsFixed(5)} '
      // 'threshold=${threshold.toStringAsFixed(5)} '
      // );
      _axis = null;
      return;
    }

    final double steps = _stepRate == 0
      ? 1 + (dist - sensitivity.firstStepTravel) / sensitivity.stepTravel
      : dist / sensitivity.stepTravel;

    final double currStepRate = _smoothing * (steps / dt) + (1.0 - _smoothing) * _stepRate;

    // Reject stepRates that are too small.
    if (currStepRate <= _minStepRate) {
      log.playback('rejected: rate too small');
      return;
    }

    final GamepadNavKey? lastDirection = _direction;
    _updateDirection(dx, dy);

    if (currStepRate > _stepRate || lastDirection != _direction) {
      _stepRate = currStepRate;
      _stopStepTimer();
    }

    // TODO: remove this logging
    log.playback(
        'dt=${dt.toStringAsFixed(3)} '
        'stepRate=${_stepRate.toStringAsFixed(3)} '
        'thisStepRate=${currStepRate.toStringAsFixed(3)} '
        );
  }

  // ---------------------------------------------------------------------------
  // Axis locking
  // ---------------------------------------------------------------------------

  void _updateAxis(double x, double y) {
    _axis = x.abs() >= y.abs() ? _Axis.horizontal : _Axis.vertical;
  }

  // ---------------------------------------------------------------------------
  // Direction
  // ---------------------------------------------------------------------------

  void _updateDirection(double x, double y) {
    final horizontal = _axis == _Axis.horizontal;

    final travel = horizontal ? x : y;

    _direction = horizontal
        ? (travel > 0
            ? GamepadNavKey.right
            : GamepadNavKey.left)
        : (travel > 0
            ? GamepadNavKey.down
            : GamepadNavKey.up);
  }

  // ---------------------------------------------------------------------------
  // Navigation steps
  // ---------------------------------------------------------------------------

  void _startStepTimer() {
    if (_stepTimer != null) {
      return;
    }

    final double interval = 1.0 / _stepRate;
    log.playback(
        'stepRate=${_stepRate.toStringAsFixed(3)} '
        'interval=${interval.toStringAsFixed(3)} '
        );

    _stepTimer = Timer(
        Duration(milliseconds: (interval * 1000).round()),
        () {
        _stepTimer = null;

        if (_direction == null || _stepRate <= _minStepRate) {
          _stepRate = 0;
          _direction = null;
          return;
        }

        _step(_direction!);

        if (!_touching && !_held) {

          _stepRate *= math.exp(-_momentumDecay * interval);

          if (_stepRate <= _minStepRate) {
            _stepRate = 0;
            _stopStepTimer();
            return;
          }

          log.playback(
              'DECAY stepRate=${_stepRate.toStringAsFixed(3)} '
              'interval=${interval.toStringAsFixed(3)}',
              );
        }

        _startStepTimer();
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

    _stopHeldTimer();
    _stopWatch.stop();

    if (_held) {
      _stopStepTimer();
      _stepRate = 0;
      _direction = null;
      _held = false;
    }

    _axis = null;
  }

  // ---------------------------------------------------------------------------
  // Timer
  // ---------------------------------------------------------------------------

  void _stopStepTimer() {
    _stepTimer?.cancel();
    _stepTimer = null;
  }

  void _stopHeldTimer() {
    _heldTimer?.cancel();
    _heldTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Output
  // ---------------------------------------------------------------------------

  void _step(GamepadNavKey direction) {
    _synthesizer.press(direction);
    _synthesizer.release(direction);
  }
}

enum _Axis {
  horizontal,
  vertical,
}

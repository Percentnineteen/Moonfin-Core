import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_tvos/flutter_tvos.dart'
    show TvRemoteController, TvRemoteTouchEvent, TvRemoteTouchPhase;

import '../../preference/preference_constants.dart'
    show SiriRemoteSwipeSensitivity;
import 'gamepad/gamepad_key_synthesizer.dart';

/// Turns Siri Remote touchpad gestures into focus navigation. Focus steps one
/// item at a time as the finger travels and stops when the finger does, so a
/// drag moves the same number of items however fast it was made.
///
/// The engine's own swipe detectors are switched off by config, since one
/// emits a single arrow per gesture and the other latches while the finger
/// rests and runs focus away. Clicks and buttons stay native. Steps go out as
/// real arrow key events through [GamepadKeySynthesizer], so every existing
/// key handler and focus widget behaves exactly as it does for a click.
///
/// While a native view controller covers Flutter the engine stops forwarding
/// touches, so this layer goes quiet on its own.

// TODO: remove these logging bits
import 'package:get_it/get_it.dart';
import '../../data/services/log_service.dart';
final log = GetIt.instance<LogService>();

class SiriRemoteGlide {
  SiriRemoteGlide._();

  static final SiriRemoteGlide instance = SiriRemoteGlide._();

  SiriRemoteSwipeSensitivity sensitivity = SiriRemoteSwipeSensitivity.medium;

  final GamepadKeySynthesizer _synthesizer = GamepadKeySynthesizer();

  bool _attached = false;

  _State _state = _State.idle;

  final Stopwatch _stopWatch = Stopwatch();
  final Stopwatch _tapStopWatch = Stopwatch();
  int? _lastStepTime = null;
  int? _stepTicks = null;
  double? _decayedStepTicks = null;
  int _stepCounter = 0;
  GamepadNavKey? _lastDirection = null;
  Timer? _stepTimer;
  GamepadNavKey? _lastTapDirection = null;

  double _lastX = 0;
  double _lastY = 0;
  double _accX = 0;
  double _accY = 0;

  // Minimum step interval; min time between steps
  static const Duration _minStepInterval = Duration(milliseconds:50);

  // Flick decay rate (k in V = V0 * exp (-k * t))
  static const double _decayConstant = 3.5;

  // Interval at which a flick stops
  static const Duration _flickStopInterval = Duration(milliseconds:350);

  // Flick timer
  static const Duration _flickThreshold = Duration(milliseconds:350);

  void attach() {
    if (_attached) return;
    _attached = true;
    TvRemoteController.instance.addRawListener(_onTouch);
  }

  @visibleForTesting
  void debugReset() {
    _synthesizer.releaseAll();
    _state = _State.idle;
  }

  @visibleForTesting
  void debugHandleTouch(TvRemoteTouchEvent event) => _onTouch(event);

  void _onTouch(TvRemoteTouchEvent event) {
    switch (event.phase) {
      case TvRemoteTouchPhase.started:
        _beginGesture(event.x, event.y);
      case TvRemoteTouchPhase.move:
        if (_state == _State.idle) {
          _beginGesture(event.x, event.y);
          return;
        }
        _onMove(event.x, event.y);
      case TvRemoteTouchPhase.ended:
      case TvRemoteTouchPhase.cancelled:
        _endGesture();
      case TvRemoteTouchPhase.loc:
        _handleLoc(event.x, event.y);
      case TvRemoteTouchPhase.clickStart:
      case TvRemoteTouchPhase.clickEnd:
        break;
    }
  }

  void _beginGesture(double x, double y) {
    // log.playback('begin gesture ${x.toStringAsFixed(3)} ${y.toStringAsFixed(3)}');
    _state = _State.touching;
    _lastX = x;
    _lastY = y;
    _accX = 0;
    _accY = 0;
    // TODO: review resetting state
    _lastStepTime = null;
    _stepTicks = null;
    _decayedStepTicks = null;
    _stopStepTimer();
    _stepCounter = 0;
    _stopWatch
      ..reset()
      ..start();
  }

  void _endGesture() {
    if (_state != _State.touching) {
      return;
    }
    // TODO: review resetting state
    // log.playback('end gesture');
    if (_stopWatch.elapsedMilliseconds >= _flickThreshold.inMilliseconds) {
      _state = _State.idle;
    } else {
      _state = _State.decaying;
    }
    _lastStepTime = null;
    _stopWatch
      ..stop()
      ..reset();
  }

  void _onMove(double x, double y) {
    final dx = x - _lastX;
    final dy = y - _lastY;
    _lastX = x;
    _lastY = y;

    // A reversal replaces the accumulator instead of unwinding it, so
    // changing direction mid drag responds immediately.
    _accX = dx.sign != 0 && dx.sign != _accX.sign ? dx : _accX + dx;
    _accY = dy.sign != 0 && dy.sign != _accY.sign ? dy : _accY + dy;

    final threshold = _lastDirection == null
      ? sensitivity.firstStepTravel
      : sensitivity.stepTravel;
    final horizontal = _accX.abs() >= _accY.abs();
    final travel = horizontal ? _accX : _accY;
    if (travel.abs() < threshold) return;

    final direction = horizontal
      ? (travel > 0 ? GamepadNavKey.right : GamepadNavKey.left)
      // The pad reports up as negative y, so travelling positive is a
      // finger moving down the surface.
      : (travel > 0 ? GamepadNavKey.down : GamepadNavKey.up);
    _stepWrapper(direction);
    if (horizontal) {
      _accX -= travel.sign * threshold;
      _accY = 0;
    } else {
      _accY -= travel.sign * threshold;
      _accX = 0;
    }
  }

  void _stepWrapper(GamepadNavKey direction) {
    final now = _stopWatch.elapsedMilliseconds;
    final lastDirection = _lastDirection;

    if (lastDirection == null || direction != lastDirection) {
      _stopStepTimer();
      _step(direction);
    } else {
      _updateStepCadence(now);
      _startStepTimer();
    }

    _lastStepTime = now;
    _lastDirection = direction;
  }

  void _updateStepCadence(int now) {
    final lastStepTime = _lastStepTime;
    if (lastStepTime == null) {
      return;
    }

    final ticks = math.max(1, ((now - lastStepTime) / _minStepInterval.inMilliseconds).round());

    final currentTicks = _stepTicks;
    if (currentTicks == null || ticks < currentTicks) {
      _stepTicks = ticks;
    }
  }

  void _startStepTimer() {
    if (_stepTimer != null) {
      return;
    }

    _stepTimer = Timer.periodic(_minStepInterval, (_) {
        _onStepTimerTick();
        });
  }

  void _onStepTimerTick() {
    if (_state == _State.idle) {
      _stopStepTimer();
      return;
    }

    final stepTicks = _stepTicks;
    _stepCounter++;
    if (stepTicks == null || _stepCounter < stepTicks) {
      _stepCounter++;
      return;
    }

    final direction = _lastDirection;
    if (direction == null) {
      _stopStepTimer();
      return;
    }

    _step(direction);
    _stepCounter = 0;

    if (_state == _State.decaying) {
      _updateDecay(stepTicks);
    }
  }

  void _updateDecay(int stepTicks) {
    var decayedStepTicks = _decayedStepTicks ?? stepTicks.toDouble();

    decayedStepTicks *= math.exp(
        _decayConstant * stepTicks * _minStepInterval.inMilliseconds / 1000.0,
        );

    if (decayedStepTicks * _minStepInterval.inMilliseconds >=
        _flickStopInterval.inMilliseconds) {
      _state = _State.idle;
    } else {
      _decayedStepTicks = decayedStepTicks;
      _stepTicks = decayedStepTicks.round();
    }
  }

  void _stopStepTimer() {
    _stepTimer?.cancel();
    _stepTimer = null;
    _stepTicks = null;
  }

  void _step(GamepadNavKey direction) {
    _synthesizer.press(direction);
    _synthesizer.release(direction);
  }

  void _handleLoc(double x, double y) {
    if (x == 0.0 || y == 0.0 || _state != _State.touching) {
      // don't reject because incomplete could come in
      // _lastTapDirection = null;
      return;
    }
    final lastDir = _lastTapDirection;
    final dir = _tapDirection(x, y);
    if (lastDir != null && lastDir == dir) {
      final interval = math.max(1, (_tapStopWatch.elapsedMilliseconds / _minStepInterval.inMilliseconds).round());
      log.playback('The tap gesture should fire ${dir?.name} at $interval');
    }
    _lastTapDirection = dir;
    _tapStopWatch
      ..reset()
      ..start();
  }
}

GamepadNavKey? _tapDirection(double x, double y) {
  log.playback('${x.toStringAsFixed(3)} ${y.toStringAsFixed(3)}');
  if (x > 0.50 && y.abs() <= 0.3) {
    return GamepadNavKey.right;
  }
  if (x < -0.50 && y.abs() <= 0.3) {
    return GamepadNavKey.left;
  }
  if (y > 0.50 && x.abs() <= 0.3) {
    return GamepadNavKey.up;
  }
  if (y < -0.50 && x.abs() <= 0.3) {
    return GamepadNavKey.down;
  }
  return null;
}

enum _State {
  idle,
  tapped,
  touching,
  decaying,
}

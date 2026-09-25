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

  bool _touching = false;

  final Stopwatch _stopWatch = Stopwatch();
  int? _lastStepTime = null;
  int? _stepTicks = null;
  int _stepCounter = 0;
  GamepadNavKey? _lastDirection = null;
  Timer? _stepTimer;

  double _lastX = 0;
  double _lastY = 0;
  double _accX = 0;
  double _accY = 0;
  bool _steppedThisGesture = false;

  // Minimum step interval; min time between steps
  static const Duration _minStepInterval = Duration(milliseconds:50);

  void attach() {
    if (_attached) return;
    _attached = true;
    TvRemoteController.instance.addRawListener(_onTouch);
  }

  @visibleForTesting
  void debugReset() {
    _synthesizer.releaseAll();
    _touching = false;
  }

  @visibleForTesting
  void debugHandleTouch(TvRemoteTouchEvent event) => _onTouch(event);

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
    log.playback('gesture start');
    _touching = true;
    _lastX = x;
    _lastY = y;
    _accX = 0;
    _accY = 0;
    _steppedThisGesture = false;
    // TODO: review resetting state
    _lastStepTime = null;
    _stepTicks = null;
    _stopStepTimer();
    _stepCounter = 0;
    _stopWatch
      ..reset()
      ..start();
  }

  void _endGesture() {
    if (!_touching) {
      return;
    }
    log.playback('gesture end');
    // TODO: review resetting state
    // TODO: this only applies for non-flick gestures
    _stopStepTimer;
    _touching = false;
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

    final threshold = _steppedThisGesture
      ? sensitivity.stepTravel
      : sensitivity.firstStepTravel;
    final horizontal = _accX.abs() >= _accY.abs();
    final travel = horizontal ? _accX : _accY;
    if (travel.abs() < threshold) return;

    final direction = horizontal
      ? (travel > 0 ? GamepadNavKey.right : GamepadNavKey.left)
      // The pad reports up as negative y, so travelling positive is a
      // finger moving down the surface.
      : (travel > 0 ? GamepadNavKey.down : GamepadNavKey.up);
    _stepWrapper(direction);
    _steppedThisGesture = true;
    if (horizontal) {
      _accX -= travel.sign * threshold;
      _accY = 0;
    } else {
      _accY -= travel.sign * threshold;
      _accX = 0;
    }
  }

  void _stepWrapper(GamepadNavKey direction) {
    final lastStepTime = _lastStepTime;
    final stepTicks = _stepTicks;

    if (_steppedThisGesture) {
      final ticks = ((_stopWatch.elapsedMilliseconds - (lastStepTime ?? 0)) / _minStepInterval.inMilliseconds).round();
      if (stepTicks == null || stepTicks > ticks || direction != _lastDirection) {
        _stepTicks = ticks;
        log.playback(
            'step interval = ${ticks.toStringAsFixed(3)}\n'
            'last steptime = ${lastStepTime?.toStringAsFixed(3)}\n'
            'stopwatch = ${_stopWatch.elapsedMilliseconds}\n'
            'interval = ${_minStepInterval.inMilliseconds}\n'
            'ticks = (stopwatch - lastStepTime) / interval'
            );
      } else {
        log.playback(
            'step interval = ${stepTicks.toStringAsFixed(3)}\n'
            'last steptime = ${lastStepTime?.toStringAsFixed(3)}\n'
            'stopwatch = ${_stopWatch.elapsedMilliseconds}\n'
            'interval = ${_minStepInterval.inMilliseconds}\n'
            'ticks = (stopwatch - lastStepTime) / interval'
            );
      }
      // _startStepTimer();
    } else {
      log.playback('first');
    }
    _lastStepTime = _stopWatch.elapsedMilliseconds;
    log.playback('STEP ${direction.name}');
    _lastDirection = direction;
    _step(direction);
  }

  void _startStepTimer() {
    if (_stepTimer != null) {
      return;
    }
    final stepTicks = _stepTicks;
    _stepTimer = Timer.periodic(_minStepInterval, (_) {
      // determine if step should fire
      if (stepTicks != null && _stepCounter >= stepTicks) {
        final direction = _lastDirection;
        if (direction != null) {
          _step(direction);
          _stepCounter = 0;
          log.playback('STEP ${direction.name}');
        }
      }
      _stepCounter +=1;
    });
  }

  void _stopStepTimer() {
    _stepTimer?.cancel();
    _stepTimer = null;
  }

  void _step(GamepadNavKey direction) {
    _synthesizer.press(direction);
    _synthesizer.release(direction);
  }
}

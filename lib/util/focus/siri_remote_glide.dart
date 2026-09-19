import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_tvos/flutter_tvos.dart'
    show TvRemoteController, TvRemoteTouchEvent, TvRemoteTouchPhase;

import '../../preference/preference_constants.dart'
    show SiriRemoteSwipeSensitivity;
import 'gamepad/gamepad_key_synthesizer.dart';

import 'package:get_it/get_it.dart';
import '../../data/services/log_service.dart';
final log = GetIt.instance<LogService>();


/// Turns Siri Remote touchpad gestures into focus navigation.
///
/// The gesture is treated as physical finger travel:
///
/// - Small movement is ignored as touch noise.
/// - The dominant axis is locked once established.
/// - Physical movement produces navigation steps.
/// - While the finger remains down after a swipe, navigation continues at a
///   rate based on the maximum velocity reached during that swipe.
/// - Slowing or stopping the finger does not slow the hold.
/// - Releasing the finger stops navigation immediately.
/// - Fast flicks of the finger result in a momentum with decay
///
/// Navigation is emitted as real arrow key events through
/// [GamepadKeySynthesizer].
class SiriRemoteGlide {
  SiriRemoteGlide._();

  static final SiriRemoteGlide instance = SiriRemoteGlide._();

  SiriRemoteSwipeSensitivity sensitivity =
      SiriRemoteSwipeSensitivity.medium;

  final GamepadKeySynthesizer _synthesizer = GamepadKeySynthesizer();

  bool _attached = false;
  bool _touching = false;

  double _lastX = 0;
  double _lastY = 0;

  double _accX = 0;
  double _accY = 0;

  double _velocityX = 0;
  double _velocityY = 0;

  double _velocity = 0;

  DateTime? _lastMoveTime;

  bool _steppedThisGesture = false;

  _Axis? _axis;
  GamepadNavKey? _direction;

  Timer? _stepTimer;
  Timer? _heldTimer;

  bool _held = false;
  static const double _momentumDecay = 2.0;
  static const double _momentumVelocityCutoff = 2.0;
  static const Duration _holdThreshold = Duration(milliseconds: 500);

  // ---------------------------------------------------------------------------
  // Gesture tuning
  // ---------------------------------------------------------------------------

  /// Minimum movement before deciding whether this is horizontal or vertical.
  static const double _axisLockDistance = 0.08;

  /// How much more one axis must move than the other before locking.
  static const double _axisLockRatio = 1.35;

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
    _stopStepTimer();
    _stopHeldTimer();
    _synthesizer.releaseAll();

    _touching = false;
    _held = false;
    _axis = null;
    _direction = null;

    _accX = 0;
    _accY = 0;

    _velocityX = 0;
    _velocityY = 0;

    _velocity = 0;

    _lastMoveTime = null;
    _steppedThisGesture = false;
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
    _stopStepTimer();

    _stopHeldTimer();

    _touching = true;
    _held = false;

 
    _heldTimer = Timer(_holdThreshold, () {
      if (_touching) {
        _held = true;
      }
    });


    _lastX = x;
    _lastY = y;

    _accX = 0;
    _accY = 0;

    _velocityX = 0;
    _velocityY = 0;

    _velocity = 0;

    _lastMoveTime = DateTime.now();

    _steppedThisGesture = false;

    _axis = null;
    _direction = null;
  }

  void _onMove(double x, double y) {
    final now = DateTime.now();

    final dx = x - _lastX;
    final dy = y - _lastY;

    final dt = _lastMoveTime == null
        ? 0.016
        : now.difference(_lastMoveTime!).inMicroseconds /
            1000000.0;

    _lastX = x;
    _lastY = y;
    _lastMoveTime = now;

    if (dt <= 0 || dt > 0.25) {
      return;
    }

    _updateVelocity(dx, dy, dt);

    _accX += dx;
    _accY += dy;

    _updateAxis();

    if (_axis == null) {
      return;
    }

    _updateDirection();

    if (_direction == null) {
      return;
    }

    final velocity = _activeVelocity.abs();

    // Keep the highest velocity reached during the entire gesture.
    if (velocity > _velocity) {
      _velocity = velocity;
      if (_stepTimer != null) {
        _stopStepTimer();
        _startStepTimer();
      }
    }

    _processMovement();

    if (_steppedThisGesture) {
      _startStepTimer();
    }
  }

  // ---------------------------------------------------------------------------
  // Velocity
  // ---------------------------------------------------------------------------

  void _updateVelocity(
    double dx,
    double dy,
    double dt,
  ) {
    final rawX = dx / dt;
    final rawY = dy / dt;

    // Keep the existing smoothing so one unusually large touch event does not
    // determine the gesture speed.
    const smoothing = 0.20;

    _velocityX =
        _velocityX * (1.0 - smoothing) +
            rawX * smoothing;

    _velocityY =
        _velocityY * (1.0 - smoothing) +
            rawY * smoothing;

    log.playback(
        'dt=${dt.toStringAsFixed(3)} '
        'raw=${math.sqrt(rawX * rawX + rawY * rawY).toStringAsFixed(2)} '
        'smooth=${math.sqrt(_velocityX * _velocityX + _velocityY * _velocityY).toStringAsFixed(2)} '
        'peak=${_velocity.toStringAsFixed(2)}',
        );
  }

  double get _activeVelocity {
    return _axis == _Axis.horizontal
        ? _velocityX
        : _velocityY;
  }

  // ---------------------------------------------------------------------------
  // Axis locking
  // ---------------------------------------------------------------------------

  void _updateAxis() {
    if (_axis != null) {
      return;
    }

    final distance = math.sqrt(
      _accX * _accX + _accY * _accY,
    );

    if (distance < _axisLockDistance) {
      return;
    }

    final x = _accX.abs();
    final y = _accY.abs();

    if (x >= y * _axisLockRatio) {
      _axis = _Axis.horizontal;
    } else if (y >= x * _axisLockRatio) {
      _axis = _Axis.vertical;
    }
  }

  // ---------------------------------------------------------------------------
  // Direction
  // ---------------------------------------------------------------------------

  void _updateDirection() {
    final horizontal = _axis == _Axis.horizontal;

    final travel = horizontal ? _accX : _accY;

    if (travel == 0) {
      return;
    }

    _direction = horizontal
        ? (travel > 0
            ? GamepadNavKey.right
            : GamepadNavKey.left)
        : (travel > 0
            ? GamepadNavKey.down
            : GamepadNavKey.up);
  }

  // ---------------------------------------------------------------------------
  // Physical movement
  // ---------------------------------------------------------------------------

  void _processMovement() {
    final horizontal = _axis == _Axis.horizontal;

    final travel = horizontal ? _accX : _accY;

    if (travel == 0) {
      return;
    }

    final threshold = _steppedThisGesture
        ? sensitivity.stepTravel
        : sensitivity.firstStepTravel;

    if (travel.abs() < threshold) {
      return;
    }

    _step(_direction!);
    _steppedThisGesture = true;

    if (horizontal) {
      _accX -= travel.sign * threshold;
      _accY = 0;
    } else {
      _accY -= travel.sign * threshold;
      _accX = 0;
    }
  }

  // ---------------------------------------------------------------------------
  // Navigation steps
  // ---------------------------------------------------------------------------

  void _startStepTimer() {
    if (_direction == null ||
        _velocity <= _momentumVelocityCutoff ||
        _stepTimer != null) {
      return;
    }

    final interval = _effectiveHoldInterval(_velocity);

    _stepTimer = Timer(
        Duration(milliseconds: interval.round()),
        () {
        _stepTimer = null;

        if (_direction == null || _velocity <= _momentumVelocityCutoff) {
          _velocity = 0;
          _direction = null;
          return;
        }

        _step(_direction!);

        if (!_touching && !_held) {
          final dt = interval / 1000.0;

          log.playback(
              'DECAY velocity=${_velocity.toStringAsFixed(2)} '
              'interval=${interval.toStringAsFixed(0)}ms',
              );

          _velocity *= math.exp(-_momentumDecay * dt);

          if (_velocity <= _momentumVelocityCutoff) {
            _velocity = 0;
            _stopStepTimer();
            return;
          }
        }

        _startStepTimer();
        },
        );
  }


  double _effectiveHoldInterval(double velocity) {
    // Physical swipe rate is approximately:
    //
    //     steps / second = velocity / stepTravel
    //
    // Therefore the equivalent time between steps is:
    //
    //     seconds / step = stepTravel / velocity
    //
    // Using the same stepTravel as physical movement makes a held swipe
    // continue at the same rate as the velocity that produced it.
    return (sensitivity.stepTravel / velocity) * 1000.0;
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

    if (_held) {
      _stopStepTimer();
      _velocity = 0;
      _direction = null;
      _held = false;
    }

    _axis = null;
    _accX = 0;
    _accY = 0;

    _velocityX = 0;
    _velocityY = 0;

    _lastMoveTime = null;
    _steppedThisGesture = false;
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

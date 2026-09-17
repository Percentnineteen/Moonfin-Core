import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_tvos/flutter_tvos.dart'
    show TvRemoteController, TvRemoteTouchEvent, TvRemoteTouchPhase;

import '../../preference/preference_constants.dart'
    show SiriRemoteSwipeSensitivity;
import 'gamepad/gamepad_key_synthesizer.dart';

/// Turns Siri Remote touchpad gestures into focus navigation.
///
/// Gesture behavior:
///
///   Swipe + hold
///     The finger continues moving slowly or comes to rest while held.
///     Navigation continues at a velocity-dependent rate until release.
///
///   Flick
///     A fast swipe followed by release continues with decaying momentum.
///
///   Flick + tap
///     A click while momentum is active immediately cancels the momentum.
///     Normal clicks are otherwise untouched.
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

  _GlideState _state = _GlideState.idle;

  double _lastX = 0;
  double _lastY = 0;

  double _accX = 0;
  double _accY = 0;

  double _velocityX = 0;
  double _velocityY = 0;

  DateTime? _lastMoveTime;

  _Axis? _axis;
  GamepadNavKey? _direction;

  Timer? _navigationTimer;
  Timer? _momentumTimer;

  double _momentumVelocity = 0;
  double _momentumAccumulator = 0;

  // ---------------------------------------------------------------------------
  // Tuning
  // ---------------------------------------------------------------------------

  /// Movement before we decide whether the gesture is horizontal or vertical.
  static const double _axisLockDistance = 0.08;

  /// Prevents a diagonal movement from immediately becoming an axis.
  static const double _axisLockRatio = 1.35;

  /// Opposite-direction travel required to commit to a reversal.
  static const double _reversalDistance = 0.12;

  /// Velocity below which movement is considered deliberate/slow.
  static const double _slowVelocity = 0.8;

  /// Velocity at which the velocity response reaches its maximum.
  static const double _fastVelocity = 5.0;

  /// Maximum reduction in physical travel required at high velocity.
  static const double _velocityResponse = 0.18;

  /// Velocity at which the gesture is considered a fast flick.
  static const double _flickVelocity = 3.0;

  /// Slowest continuous navigation interval.
  static const Duration _slowNavigationInterval =
      Duration(milliseconds: 260);

  /// Fastest continuous navigation interval.
  static const Duration _fastNavigationInterval =
      Duration(milliseconds: 70);

  /// Interval used to update momentum.
  static const Duration _momentumInterval =
      Duration(milliseconds: 16);

  /// Momentum decay per tick.
  static const double _momentumDecay = 0.91;

  /// Momentum stops below this velocity.
  static const double _minimumMomentumVelocity = 0.45;

  /// How strongly momentum translates velocity into navigation steps.
  static const double _momentumStepRate = 0.075;

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
    _stopAllTimers();
    _synthesizer.releaseAll();

    _touching = false;
    _state = _GlideState.idle;
    _axis = null;
    _direction = null;

    _accX = 0;
    _accY = 0;

    _velocityX = 0;
    _velocityY = 0;

    _lastMoveTime = null;
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
        _endGesture();

      case TvRemoteTouchPhase.cancelled:
        _cancelGesture();

      case TvRemoteTouchPhase.clickStart:
        _onClickStart();

      case TvRemoteTouchPhase.clickEnd:
        // Normal click handling remains native.
        break;

      case TvRemoteTouchPhase.loc:
        break;
    }
  }

  void _beginGesture(double x, double y) {
    // A new touch always cancels previous momentum.
    _stopMomentum();

    _touching = true;
    _state = _GlideState.tracking;

    _axis = null;
    _direction = null;

    _lastX = x;
    _lastY = y;

    _accX = 0;
    _accY = 0;

    _velocityX = 0;
    _velocityY = 0;

    _lastMoveTime = DateTime.now();
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

    _processMovement();
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

    // Smooth the raw touch velocity. This prevents individual touch events
    // from causing large changes in navigation speed.
    const smoothing = 0.20;

    _velocityX =
        _velocityX * (1.0 - smoothing) +
            rawX * smoothing;

    _velocityY =
        _velocityY * (1.0 - smoothing) +
            rawY * smoothing;
  }

  double get _activeVelocity {
    if (_axis == _Axis.horizontal) {
      return _velocityX;
    }

    return _velocityY;
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
  // Finger-driven navigation
  // ---------------------------------------------------------------------------

  void _processMovement() {
    final horizontal = _axis == _Axis.horizontal;

    final travel = horizontal ? _accX : _accY;

    if (travel == 0) {
      return;
    }

    final newDirection = horizontal
        ? (travel > 0
            ? GamepadNavKey.right
            : GamepadNavKey.left)
        : (travel > 0
            ? GamepadNavKey.down
            : GamepadNavKey.up);

    // -----------------------------------------------------------------------
    // Direction reversal
    // -----------------------------------------------------------------------

    if (_direction != null && newDirection != _direction) {
      if (travel.abs() < _reversalDistance) {
        return;
      }

      // Discard the old direction's accumulated travel.
      _accX = horizontal ? travel : 0;
      _accY = horizontal ? 0 : travel;

      _direction = newDirection;
    }

    if (_direction == null) {
      _direction = newDirection;
    }

    final threshold = _effectiveStepTravel(
      _activeVelocity.abs(),
    );

    if (travel.abs() < threshold) {
      _updateHoldNavigation();
      return;
    }

    _step(_direction!);

    if (horizontal) {
      _accX -= travel.sign * threshold;
      _accY = 0;
    } else {
      _accY -= travel.sign * threshold;
      _accX = 0;
    }

    _state = _GlideState.swiping;

    _updateHoldNavigation();
  }

  double _effectiveStepTravel(double velocity) {
    final base = _state == _GlideState.tracking
        ? sensitivity.firstStepTravel
        : sensitivity.stepTravel;

    final speed = ((velocity - _slowVelocity) /
            (_fastVelocity - _slowVelocity))
        .clamp(0.0, 1.0);

    // Ease the velocity response so slow movements remain predictable.
    final eased = speed * speed;

    return base * (1.0 - (_velocityResponse * eased));
  }

  // ---------------------------------------------------------------------------
  // Swipe + hold
  // ---------------------------------------------------------------------------

  void _updateHoldNavigation() {
    if (!_touching || _direction == null) {
      _stopNavigationTimer();
      return;
    }

    final speed = _activeVelocity.abs();

    if (speed < _slowVelocity) {
      _stopNavigationTimer();
      return;
    }

    if (_navigationTimer?.isActive ?? false) {
      return;
    }

    final interval = _navigationInterval(speed);

    _navigationTimer = Timer(
      interval,
      () {
        _navigationTimer = null;

        if (!_touching || _direction == null) {
          return;
        }

        final currentSpeed = _activeVelocity.abs();

        if (currentSpeed < _slowVelocity) {
          return;
        }

        _step(_direction!);
        _updateHoldNavigation();
      },
    );
  }

  Duration _navigationInterval(double velocity) {
    final speed = ((velocity - _slowVelocity) /
            (_fastVelocity - _slowVelocity))
        .clamp(0.0, 1.0);

    // Quadratic easing gives a gentle acceleration curve.
    final eased = speed * speed;

    final milliseconds =
        _slowNavigationInterval.inMilliseconds +
            ((_fastNavigationInterval.inMilliseconds -
                    _slowNavigationInterval.inMilliseconds) *
                eased);

    return Duration(
      milliseconds: milliseconds.round(),
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
    _stopNavigationTimer();

    final velocity = _activeVelocity;

    if (_axis != null &&
        velocity.abs() >= _flickVelocity) {
      _startMomentum(velocity);
    } else {
      _state = _GlideState.idle;
      _axis = null;
      _direction = null;
    }

    _lastMoveTime = null;
  }

  void _cancelGesture() {
    _touching = false;

    _stopAllTimers();

    _state = _GlideState.idle;
    _axis = null;
    _direction = null;

    _accX = 0;
    _accY = 0;

    _velocityX = 0;
    _velocityY = 0;

    _lastMoveTime = null;
  }

  // ---------------------------------------------------------------------------
  // Flick + momentum
  // ---------------------------------------------------------------------------

  void _startMomentum(double velocity) {
    _stopMomentum();

    _state = _GlideState.momentum;

    _momentumVelocity = velocity;
    _momentumAccumulator = 0;

    _momentumTimer = Timer.periodic(
      _momentumInterval,
      (_) {
        final speed = _momentumVelocity.abs();

        if (speed < _minimumMomentumVelocity) {
          _stopMomentum();
          return;
        }

        final direction = _axis == _Axis.horizontal
            ? (_momentumVelocity > 0
                ? GamepadNavKey.right
                : GamepadNavKey.left)
            : (_momentumVelocity > 0
                ? GamepadNavKey.down
                : GamepadNavKey.up);

        final normalizedSpeed =
            (speed / _fastVelocity).clamp(0.0, 1.0);

        _momentumAccumulator +=
            normalizedSpeed * _momentumStepRate;

        while (_momentumAccumulator >= 1.0) {
          _step(direction);
          _momentumAccumulator -= 1.0;
        }

        _momentumVelocity *= _momentumDecay;
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Flick + tap cancellation
  // ---------------------------------------------------------------------------

  void _onClickStart() {
    if (_state != _GlideState.momentum) {
      return;
    }

    // A tap during momentum is explicitly treated as "stop".
    _stopMomentum();

    _state = _GlideState.idle;
    _axis = null;
    _direction = null;
  }

  // ---------------------------------------------------------------------------
  // Timers
  // ---------------------------------------------------------------------------

  void _stopNavigationTimer() {
    _navigationTimer?.cancel();
    _navigationTimer = null;
  }

  void _stopMomentum() {
    _momentumTimer?.cancel();
    _momentumTimer = null;

    _momentumVelocity = 0;
    _momentumAccumulator = 0;
  }

  void _stopAllTimers() {
    _stopNavigationTimer();
    _stopMomentum();
  }

  // ---------------------------------------------------------------------------
  // Key output
  // ---------------------------------------------------------------------------

  void _step(GamepadNavKey direction) {
    _synthesizer.press(direction);
    _synthesizer.release(direction);

    _direction = direction;
  }
}

enum _GlideState {
  idle,
  tracking,
  swiping,
  momentum,
}

enum _Axis {
  horizontal,
  vertical,
}


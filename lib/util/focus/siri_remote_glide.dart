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
/// The gesture is treated as physical finger travel rather than a conventional
/// swipe:
///
/// - Small movement is ignored as touch noise.
/// - The dominant axis is locked once established.
/// - Slow movement remains deliberate.
/// - Faster movement becomes progressively more responsive.
/// - Direction reversals have a small hysteresis zone.
/// - A sufficiently fast release produces a small amount of decaying
///   momentum.
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

  DateTime? _lastMoveTime;

  bool _steppedThisGesture = false;

  _Axis? _axis;
  GamepadNavKey? _direction;

  Timer? _momentumTimer;
  double _momentumVelocity = 0;
  double _momentumAccumulator = 0;

  // ---------------------------------------------------------------------------
  // Gesture tuning
  // ---------------------------------------------------------------------------

  /// Minimum movement before deciding whether this is horizontal or vertical.
  ///
  /// This is intentionally small because the remote coordinates are
  /// normalized.
  static const double _axisLockDistance = 0.08;

  /// How much more one axis must move than the other before locking.
  static const double _axisLockRatio = 1.35;

  /// Opposite-direction travel required to commit to a reversal.
  static const double _reversalDistance = 0.12;

  /// Velocity at which we consider the gesture "fast".
  static const double _slowVelocity = 0.8;

  /// Velocity at which the response reaches its maximum acceleration.
  static const double _fastVelocity = 5.0;

  /// Maximum reduction in step distance caused by high velocity.
  ///
  /// 0.18 = up to 18% less travel required at high speed.
  static const double _velocityResponse = 0.18;

  /// Minimum velocity required to create post-release momentum.
  static const double _flickVelocity = 3.0;

  /// Momentum update interval.
  static const Duration _momentumInterval =
      Duration(milliseconds: 16);

  /// Momentum decay per tick.
  static const double _momentumDecay = 0.91;

  /// Momentum stops below this velocity.
  static const double _minimumMomentumVelocity = 0.45;

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
    _cancelMomentum();
    _synthesizer.releaseAll();

    _touching = false;
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

      case TvRemoteTouchPhase.loc:
      case TvRemoteTouchPhase.clickStart:
      case TvRemoteTouchPhase.clickEnd:
        break;
    }
  }

  void _beginGesture(double x, double y) {
    _cancelMomentum();

    _touching = true;

    _lastX = x;
    _lastY = y;

    _accX = 0;
    _accY = 0;

    _velocityX = 0;
    _velocityY = 0;

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

    // Touch events can arrive at slightly irregular intervals. Smooth the
    // velocity so one unusually large event doesn't cause a giant jump.
    const smoothing = 0.20;

    _velocityX =
        _velocityX * (1.0 - smoothing) +
            rawX * smoothing;

    _velocityY =
        _velocityY * (1.0 - smoothing) +
            rawY * smoothing;
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
  // Navigation
  // ---------------------------------------------------------------------------

  //void _processMovement() {
  //  final horizontal = _axis == _Axis.horizontal;

  //  final travel = horizontal ? _accX : _accY;
  //  final velocity = horizontal ? _velocityX : _velocityY;

  //  if (travel == 0) {
  //    return;
  //  }

  //  final newDirection = horizontal
  //      ? (travel > 0
  //          ? GamepadNavKey.right
  //          : GamepadNavKey.left)
  //      : (travel > 0
  //          ? GamepadNavKey.down
  //          : GamepadNavKey.up);

  //  // -----------------------------------------------------------------------
  //  // Reversal hysteresis
  //  // -----------------------------------------------------------------------

  //  if (_direction != null &&
  //      newDirection != _direction) {
  //    if (travel.abs() < _reversalDistance) {
  //      return;
  //    }

  //    // We've moved far enough in the opposite direction to commit.
  //    _accX = horizontal ? travel : 0;
  //    _accY = horizontal ? 0 : travel;

  //    _direction = newDirection;
  //  }

  //  if (_direction == null) {
  //    _direction = newDirection;
  //  }

  //  // -----------------------------------------------------------------------
  //  // Velocity-sensitive travel
  //  // -----------------------------------------------------------------------

  //  final threshold = _effectiveStepTravel(
  //    velocity.abs(),
  //  );

  //  if (travel.abs() < threshold) {
  //    return;
  //  }

  //  _step(_direction!);

  //  if (horizontal) {
  //    _accX -= travel.sign * threshold;
  //    _accY = 0;
  //  } else {
  //    _accY -= travel.sign * threshold;
  //    _accX = 0;
  //  }
  //}

  void _processMovement() {
    final horizontal = _axis == _Axis.horizontal;

    final travel = horizontal ? _accX : _accY;
    final velocity = horizontal ? _velocityX : _velocityY;

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

    // Don't immediately reverse because of tiny finger corrections.
    if (_direction != null && newDirection != _direction) {
      if (travel.abs() < _reversalDistance) {
        return;
      }

      _accX = horizontal ? travel : 0;
      _accY = horizontal ? 0 : travel;

      _direction = newDirection;
    }

    if (_direction == null) {
      _direction = newDirection;
    }

    final threshold = _effectiveStepTravel(
        velocity.abs(),
        );

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


  //double _effectiveStepTravel(double velocity) {
  //  final base = sensitivity.stepTravel;

  //  final speed = ((velocity - _slowVelocity) /
  //          (_fastVelocity - _slowVelocity))
  //      .clamp(0.0, 1.0);

  //  // Smooth acceleration curve.
  //  final eased = speed * speed;

  //  // At high velocity the finger needs slightly less physical travel to
  //  // produce the next navigation event.
  //  return base *
  //      (1.0 - (_velocityResponse * eased));
  //}

  double _effectiveStepTravel(double velocity) {
    final base = _steppedThisGesture
      ? sensitivity.stepTravel
      : sensitivity.firstStepTravel;

    final speed = ((velocity - _slowVelocity) /
        (_fastVelocity - _slowVelocity))
      .clamp(0.0, 1.0);

    final eased = speed * speed;

    return base * (1.0 - (_velocityResponse * eased));
  }


  void _step(GamepadNavKey direction) {
    _synthesizer.press(direction);
    _synthesizer.release(direction);

    _direction = direction;
  }

  // ---------------------------------------------------------------------------
  // Gesture ending
  // ---------------------------------------------------------------------------

  void _endGesture() {
    if (!_touching) {
      return;
    }

    _touching = false;

    final velocity = _axis == _Axis.horizontal
        ? _velocityX
        : _velocityY;

    if (_axis != null &&
        velocity.abs() >= _flickVelocity) {
      _startMomentum(velocity);
    }

    _lastMoveTime = null;
  }

  void _cancelGesture() {
    _touching = false;

    _cancelMomentum();

    _axis = null;
    _direction = null;

    _accX = 0;
    _accY = 0;

    _velocityX = 0;
    _velocityY = 0;

    _lastMoveTime = null;
  }

  // ---------------------------------------------------------------------------
  // Momentum
  // ---------------------------------------------------------------------------

  void _startMomentum(double velocity) {
    _cancelMomentum();

    _momentumVelocity = velocity;
    _momentumAccumulator = 0;

    _momentumTimer = Timer.periodic(
      _momentumInterval,
      (_) {
        final speed = _momentumVelocity.abs();

        if (speed < _minimumMomentumVelocity) {
          _cancelMomentum();
          return;
        }

        final direction = _axis == _Axis.horizontal
            ? (_momentumVelocity > 0
                ? GamepadNavKey.right
                : GamepadNavKey.left)
            : (_momentumVelocity > 0
                ? GamepadNavKey.down
                : GamepadNavKey.up);

        // Convert velocity into fractional navigation distance.
        //
        // This is deterministic: there is no random chance involved.
        final normalizedSpeed =
            (speed / _fastVelocity).clamp(0.0, 1.0);

        _momentumAccumulator +=
            normalizedSpeed * 0.075;

        while (_momentumAccumulator >= 1.0) {
          _step(direction);
          _momentumAccumulator -= 1.0;
        }

        _momentumVelocity *= _momentumDecay;
      },
    );
  }

  void _cancelMomentum() {
    _momentumTimer?.cancel();
    _momentumTimer = null;

    _momentumVelocity = 0;
    _momentumAccumulator = 0;
  }
}

enum _Axis {
  horizontal,
  vertical,
}

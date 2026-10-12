//! The small maths of motion: a time as a 0 to 1 ramp, a blend between two values, and the
//! easing curves. Plain f32 arithmetic with no trig, exp or pow and no fused multiply-add, so
//! every build rounds alike.

/// How far `t` is from `from` towards `from + secs`: 0 before, 1 from `from + secs` on.
pub(super) fn ramp(t: f32, from: f32, secs: f32) -> f32 {
    ((t - from) / secs).clamp(0.0, 1.0)
}

/// `a` at `k` = 0, `b` at `k` = 1.
pub(super) fn lerp(a: f32, b: f32, k: f32) -> f32 {
    a + (b - a) * k
}

/// A fast start that settles without overshoot.
pub(super) fn ease_out_quad(p: f32) -> f32 {
    1.0 - (1.0 - p) * (1.0 - p)
}

/// CSS `cubic-bezier(0.4, 1.6, 0.6, 1)`: a fast rise that overshoots, then settles.
pub(super) fn overshoot(p: f32) -> f32 {
    let bez = |a: f32, b: f32, s: f32| {
        let u = 1.0 - s;
        3.0 * u * u * s * a + 3.0 * u * s * s * b + s * s * s
    };
    let (mut lo, mut hi) = (0.0f32, 1.0f32);
    for _ in 0..24 {
        let mid = 0.5 * (lo + hi);
        if bez(0.4, 0.6, mid) < p {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    bez(1.6, 1.0, 0.5 * (lo + hi))
}

pub(super) fn linear(p: f32) -> f32 {
    p
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overshoot_starts_at_zero_ends_at_one_and_overshoots() {
        assert!(overshoot(0.0).abs() < 1e-4);
        assert!((overshoot(1.0) - 1.0).abs() < 1e-4);
        assert!(
            (0..=100)
                .map(|i| overshoot(i as f32 / 100.0))
                .fold(0.0, f32::max)
                > 1.05
        );
    }

    #[test]
    fn a_ramp_is_clamped_and_a_lerp_hits_both_ends() {
        assert_eq!(ramp(0.0, 1.0, 2.0), 0.0);
        assert_eq!(ramp(2.0, 1.0, 2.0), 0.5);
        assert_eq!(ramp(9.0, 1.0, 2.0), 1.0);
        assert_eq!((lerp(2.0, 6.0, 0.0), lerp(2.0, 6.0, 1.0)), (2.0, 6.0));
        assert_eq!((ease_out_quad(0.0), ease_out_quad(1.0)), (0.0, 1.0));
    }
}

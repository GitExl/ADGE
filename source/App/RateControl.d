module App.RateControl;

import std.math;
import std.algorithm;


// Largest pitch deviation applied. 0.5% is about 9 cents, below what is audible.
private immutable double MAX_DEVIATION = 0.005;

// Emulation runs on the system clock, playback on the sound card's. The two never match exactly, so
// without correction the audio queue slowly drifts until it underruns or overflows.
// Returns a ratio to scale the output sample rate by, steering the queued samples towards target.
// Example: an empty queue yields 1.005, meaning 0.5% more samples are produced per emulated second.
public double rateRatio(immutable uint queued, immutable uint target) {
    immutable double error = (cast(double)target - queued) / target;
    return 1.0 + clamp(error * MAX_DEVIATION, -MAX_DEVIATION, MAX_DEVIATION);
}

unittest {
    assert(isClose(rateRatio(1024, 1024), 1.0));
    assert(isClose(rateRatio(0, 1024), 1.0 + MAX_DEVIATION));
    assert(isClose(rateRatio(512, 1024), 1.0 + MAX_DEVIATION / 2));
    assert(isClose(rateRatio(1536, 1024), 1.0 - MAX_DEVIATION / 2));
    assert(isClose(rateRatio(3000, 1024), 1.0 - MAX_DEVIATION));
}

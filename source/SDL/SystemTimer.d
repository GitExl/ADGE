module Interface.SDL.SystemTimer;

import std.stdio;

import bindbc.sdl.bind.sdltimer;

import Interface.ISystemTimer;


// SDL_Delay can oversleep by up to a scheduler tick, so stop sleeping this many microseconds early and busy-wait the rest.
private immutable ulong SLEEP_MARGIN = 1500;
public class SystemTimer : ISystemTimer {
    private ulong _startTime;
    private ulong _endTime;

    private double _performanceFrequency;

    public this() {
        _performanceFrequency = cast(double)SDL_GetPerformanceFrequency();
    }

    public void start() {
        _startTime = getCounter();
    }

    public ulong stop() {
        _endTime = getCounter();
        return _endTime - _startTime;
    }

    public void wait(const ulong delay) {
        immutable ulong end = getCounter() + delay;

        if (delay > SLEEP_MARGIN) {
            SDL_Delay(cast(uint)((delay - SLEEP_MARGIN) / 1000));
        }
        while (getCounter() < end) {
            SDL_Delay(0);
        }
    }

    public ulong getCounter() {
        return cast(ulong)((SDL_GetPerformanceCounter() / _performanceFrequency) * 1000000);
    }
}

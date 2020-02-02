module Interface.SDL.SystemTimer;

import std.stdio;

import derelict.sdl2.sdl;

import Interface.ISystemTimer;

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
        static long fudge;

        // Suspend thread and measure how long the suspension lasted.
        ulong delayStart = getCounter();
        if (cast(int)(delay - fudge) / 1000 < 0) {
            fudge -= 5;
            return;
        }
        SDL_Delay(cast(int)(delay - fudge) / 1000);
        const long delayTime = getCounter() - delayStart;

        // If the thread was suspended too long, wait less next time.
        if (delayTime > delay) {
            fudge += 10;

        // Busywait the remaining period.
        } else if (delayTime < delay) {
            delayStart = getCounter();
            while(getCounter() - delayStart < delay - delayTime) {
                SDL_Delay(0);
            }
        }
    }

    public ulong getCounter() {
        return cast(ulong)((SDL_GetPerformanceCounter() / _performanceFrequency) * 1000000);
    }
}

import std.stdio;
import std.string;

import core.stdc.string;

import bindbc.sdl;

import Core.Joypad;
import Core.Gameboy;

import App.Config;

import Interface.ISystemTimer;
import Interface.IVideoOut;
import Interface.IAudioOut;

import Interface.SDL.VideoOut;
import Interface.SDL.AudioOut;
import Interface.SDL.SystemTimer;


private Config cfg;

private bool running;
private ubyte[SDL_NUM_SCANCODES] keys;
private int fastForwardFrameSkip = 5;


int main(string[] argv) {
    cfg = new Config("config.json");

    if (argv.length < 2) {
        writeln("Missing agument: ROM filename.");
        return -1;
    }
    string fileName = argv[1];

    initSDL();

    ISystemTimer timer = new SystemTimer();
    IVideoOut videoOut = new VideoOut(cfg, "GameBoy2");
    IAudioOut audioOut = new AudioOut(cfg);

    fastForwardFrameSkip = cast(int)cfg.get("gameboy.fast_forward_frameskip").integer;
    if (fastForwardFrameSkip < 2 || fastForwardFrameSkip > 60) {
        throw new Exception("fast_forward_frameskip must be from 2 to 60.");
    }

    Gameboy gameboy = new Gameboy(cfg.get("gameboy.mode").str, cfg.get("gameboy.boot_rom").str);
    gameboy.loadCart(fileName);
    videoOut.setWindowTitle("GameBoy2 - " ~ gameboy.cart.title);
    
    gameboy.lcd.vblankCallback = delegate void() {
        static ulong frame;
        frame++;

        const bool render = !keys[SDL_SCANCODE_GRAVE] || (frame % fastForwardFrameSkip) == 0;

        if (render) {
            videoOut.renderFrame(gameboy.lcd.buffer);
        }
        
        if (!videoOut.vsync) {
            if (!keys[SDL_SCANCODE_GRAVE]) {
                immutable long delay = cast(long)((1.0 / gameboy.videoRefreshRate) * 1000000 - timer.stop());
                if (delay > 0) {
                    timer.wait(delay);
                }
                timer.start();
            }
        }
    };
    
    gameboy.apu.setSystemSampleRate(audioOut.sampleRate);
    gameboy.apu.setHighpassFilterEnabled(cfg.get("sound.highpass_filter").boolean);
    gameboy.apu.bufferFullFunction = delegate void(immutable double[2] buffer) {
        audioOut.queueSample(buffer);
    };

    SDL_Event event;
    running = true;
    timer.start();
    while (running) {
        if (SDL_PollEvent(&event)) {
            switch (event.type) {
                case SDL_QUIT:
                    running = false;
                    break;
                case SDL_KEYUP:
                    if (keys[event.key.keysym.scancode] == true) {
                        updateJoypad(gameboy.joypad, event.key.keysym.scancode, false);
                    }
                    keys[event.key.keysym.scancode] = false;
                    break;
                case SDL_KEYDOWN:
                    if (keys[event.key.keysym.scancode] == false) {
                        updateJoypad(gameboy.joypad, event.key.keysym.scancode, true);
                    }
                    keys[event.key.keysym.scancode] = true;
                    break;
                default:
                    break;
            }
        }

        if (keys[SDL_SCANCODE_ESCAPE]) {
            running = false;
        }
        if (keys[SDL_SCANCODE_TAB]) {
            gameboy.dbg.open();
        }
        
        gameboy.executeFrame();
    }

    gameboy.cart.storeRAM();

    audioOut.destroy();
    videoOut.destroy();
    destroySDL();
    return 0;
}

private void updateJoypad(Joypad joypad, immutable int scancode, immutable bool state) {

    // A, B.
    if (scancode == SDL_SCANCODE_A) {
        joypad.setKeyState(Key.A, state);
    } else if (scancode == SDL_SCANCODE_S) {
        joypad.setKeyState(Key.B, state);
    
    // Start, select.
    } else if (scancode == SDL_SCANCODE_RETURN) {
        joypad.setKeyState(Key.START, state);
    } else if (scancode == SDL_SCANCODE_RSHIFT) {
        joypad.setKeyState(Key.SELECT, state);

    // Direction pad.
    } else if (scancode == SDL_SCANCODE_UP) {
        joypad.setKeyState(Key.UP, state);
    } else if (scancode == SDL_SCANCODE_DOWN) {
        joypad.setKeyState(Key.DOWN, state);
    } else if (scancode == SDL_SCANCODE_LEFT) {
        joypad.setKeyState(Key.LEFT, state);
    } else if (scancode == SDL_SCANCODE_RIGHT) {
        joypad.setKeyState(Key.RIGHT, state);
    }
}

private void initSDL() {
    SDLSupport ret = loadSDL();
    if (ret != sdlSupport) {
        if (ret == SDLSupport.noLibrary) {
            throw new Exception("Unable to load SDL, no library found.");
        }
        if (ret == SDLSupport.badLibrary) {
            throw new Exception("Unable to load SDL, mismatched library version found.");
        }
    }

    SDL_version sdlVersionCompiled;
    SDL_version sdlVersionLinked;
    
    SDL_VERSION(&sdlVersionCompiled);
    SDL_GetVersion(&sdlVersionLinked);

    writefln("SDL (compile) %d.%d.%d", sdlVersionCompiled.major, sdlVersionCompiled.minor, sdlVersionCompiled.patch); 
    writefln("SDL (linked)  %d.%d.%d", sdlVersionLinked.major, sdlVersionLinked.minor, sdlVersionLinked.patch);

    SDL_Init(0);
}

private void destroySDL() {
    SDL_Quit();
}

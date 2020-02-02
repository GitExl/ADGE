module Interface.SDL.VideoOut;

import std.stdio;
import std.string;

import derelict.sdl2.sdl;

import Interface.IVideoOut;

import Palette;
import Config;


private immutable uint LCD_WIDTH = 160;
private immutable uint LCD_HEIGHT = 144;

public final class VideoOut : IVideoOut {
    private SDL_Window* _window;
    private SDL_Renderer* _renderer;
    private SDL_Rect _renderDest;
	
    private SDL_Texture*[] _lcdTextures;
    private int _currentLCDTexture;
    
    private Palette _palette;
    
    private uint _scale;
    private bool _vsync;
    private uint _blurFrames;
    private string _filter;

    private uint _borderHorizontal;
    private uint _borderVertical;
    private uint _viewportWidth;
    private uint _viewportHeight;

    private ubyte[LCD_WIDTH * LCD_HEIGHT * 4] _pixelBuffer;

    public this(Config cfg, string windowTitle) {
        loadConfig(cfg);

        _viewportWidth = LCD_WIDTH + _borderHorizontal * 2;
        _viewportHeight = LCD_HEIGHT + _borderVertical * 2;

        _lcdTextures.length = _blurFrames;

        SDL_InitSubSystem(SDL_INIT_VIDEO);

        _window = SDL_CreateWindow(
            windowTitle.toStringz,
            SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
            _viewportWidth * _scale, _viewportHeight * _scale,
            SDL_WINDOW_SHOWN | SDL_WINDOW_ALLOW_HIGHDPI
        );
        if (_window is null) {
            throw new Throwable(format("Could not create window: %s", SDL_GetError()));
        }

        _renderer = SDL_CreateRenderer(
            _window, -1,
            cast(SDL_RendererFlags)(SDL_RENDERER_ACCELERATED | SDL_RENDERER_TARGETTEXTURE | (_vsync ? SDL_RENDERER_PRESENTVSYNC : 0))
        );
        if (_renderer is null) {
            throw new Throwable(format("Could not create renderer: %s", SDL_GetError()));
        }

        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, _filter.toStringz);
        SDL_RenderSetLogicalSize(_renderer, _viewportWidth * _scale, _viewportHeight * _scale);

		foreach (int i; 0.._blurFrames) {
			_lcdTextures[i] = SDL_CreateTexture(
				_renderer,
				SDL_PIXELFORMAT_RGBA8888,
				SDL_TEXTUREACCESS_STREAMING,
				LCD_WIDTH, LCD_HEIGHT
			);
			if (_lcdTextures[i] == null) {
				throw new Throwable(format("Could not create LCD texture %d: %s", i, SDL_GetError()));
			}
            SDL_SetTextureBlendMode(_lcdTextures[i], SDL_BLENDMODE_BLEND);
		}

        _renderDest.x = _borderHorizontal * _scale;
        _renderDest.y = _borderVertical * _scale;
        _renderDest.w = LCD_WIDTH * _scale;
        _renderDest.h = LCD_HEIGHT * _scale;
    }

    public void destroy() {
        SDL_DestroyRenderer(_renderer);
        SDL_DestroyWindow(_window);
    }

    public void renderFrame(const ushort[] buffer) {
        for (int i = 0; i < buffer.length; i++) {
            immutable ubyte index = buffer[i] & 0x3;
            _pixelBuffer[i * 4 + 3] = _palette.screen[index][0];
            _pixelBuffer[i * 4 + 2] = _palette.screen[index][1];
            _pixelBuffer[i * 4 + 1] = _palette.screen[index][2];
            _pixelBuffer[i * 4 + 0] = 0xFF;
        }
        SDL_UpdateTexture(_lcdTextures[_currentLCDTexture], null, &_pixelBuffer[0], LCD_WIDTH * 4);

        // Copy buffer texture to render target.
        SDL_SetRenderTarget(_renderer, null);
        SDL_SetRenderDrawColor(_renderer, _palette.border[0], _palette.border[1], _palette.border[2], 0xFF);
        SDL_RenderClear(_renderer);

        if (_blurFrames > 0) {
            int frameIndex = _currentLCDTexture - _blurFrames;
            if (frameIndex < 0) {
                frameIndex = _blurFrames + frameIndex;
            }
            foreach (int i; 0.._blurFrames) {
                immutable ubyte alpha = cast(ubyte)(255 - i * (255 / _blurFrames));
                SDL_SetTextureAlphaMod(_lcdTextures[frameIndex], alpha);
                SDL_RenderCopy(_renderer, _lcdTextures[frameIndex], null, &_renderDest);
                frameIndex = (frameIndex + 1) % _blurFrames;
            }
            _currentLCDTexture = (_currentLCDTexture + 1) % _blurFrames;
        } else {
            SDL_RenderCopy(_renderer, _lcdTextures[0], null, &_renderDest);
        }

        SDL_RenderPresent(_renderer);
    }

    public void setWindowTitle(string title) {
        SDL_SetWindowTitle(_window, title.toStringz);
    }

    private void loadConfig(Config cfg) {
        _scale = cast(uint)cfg.get("display.scale").integer;
        if (_scale < 1 || _scale > 16) {
            throw new Exception("Display scale is invalid.");
        }

        _blurFrames = cast(uint)cfg.get("display.blur_frames").integer;
        if (_blurFrames > 10) {
            throw new Exception("Cannot have more than 10 blur frames.");
        }

        _vsync = cfg.get("display.vsync").boolean;
        _borderHorizontal = cast(uint)cfg.get("display.border_horizontal").integer;
        _borderVertical = cast(uint)cfg.get("display.border_vertical").integer;
        _filter = cfg.get("display.filter").str;
        
        _palette = new Palette();
        _palette.read(cfg.get("display.palette").str);
    }

    @property
    public bool vsync() {
        return _vsync;
    }
}

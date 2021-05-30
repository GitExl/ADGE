module Interface.SDL.AudioOut;

import std.conv;
import std.stdio;
import std.format;

import bindbc.sdl.bind.sdl;
import bindbc.sdl.bind.sdlerror;
import bindbc.sdl.bind.sdlaudio;

import App.Config;

import Interface.IAudioOut;


public final class AudioOut : IAudioOut {

    private int _deviceId;
    private uint _sampleRate;
    private int _bufferSize;
    private double _volume;
    private int _deviceIndex;
    
    private string _outputFilename;
    private File _outputFile;

    public this(Config cfg) {
        loadConfig(cfg);

        SDL_InitSubSystem(SDL_INIT_AUDIO);

        SDL_AudioSpec desired;
        SDL_AudioSpec obtained;
        desired.freq = _sampleRate;
        desired.format = AUDIO_S16SYS;
        desired.channels = 2;
        desired.samples = cast(ushort)_bufferSize;
        desired.callback = null;

        const(char)* name = SDL_GetAudioDeviceName(_deviceIndex, 0);
        _deviceId = SDL_OpenAudioDevice(name, 0, &desired, &obtained, SDL_AUDIO_ALLOW_FREQUENCY_CHANGE);
        if (_deviceId < 0) {
            throw new Exception(format("Could not open audio device for playback. %s", SDL_GetError()));
        }

        writefln("Using '%s' at %d Hz, %d channel(s), %d samples in buffer.",
                 to!string(name), obtained.freq, obtained.channels, obtained.samples);

        _sampleRate = obtained.freq;
        _bufferSize = obtained.samples;

        SDL_PauseAudioDevice(_deviceId, 0);

        if (_outputFilename.length) {
            _outputFile = File(_outputFilename, "wb");
        }
    }

    public void queueSample(immutable double[2] buffer) {
        
        // Convert the sample to signed 16 bit integer and queue it.
        short[2] output = [
            buffer[0] < 0 ? cast(short)((buffer[0] * _volume) * 32767) : cast(short)((buffer[0] * _volume) * 32768),
            buffer[1] < 0 ? cast(short)((buffer[1] * _volume) * 32767) : cast(short)((buffer[1] * _volume) * 32768),
        ];

        if (_outputFile.isOpen) {
            _outputFile.rawWrite(output);
        }

        // Prevent overflow by limiting queued samples to 1/16th of a second.
        // This is useful for fast-forwarding, but should never happen during normal execution.
        if (SDL_GetQueuedAudioSize(_deviceId) / (short.sizeof * 2) >= _sampleRate / 16) {
            return;
        }

        SDL_QueueAudio(_deviceId, &output[0], output.length * short.sizeof);
    }

    public void destroy() {
        SDL_CloseAudioDevice(_deviceId);

        if (_outputFile.isOpen) {
            _outputFile.close();
        }
    }

    private void loadConfig(Config cfg) {
        _bufferSize = cast(uint)cfg.get("sound.buffer_size").integer;
        if (_bufferSize < 64 || _bufferSize > 10240) {
            throw new Exception("Audio buffer size must be 64 to 10240 samples.");
        }

        _sampleRate = cast(uint)cfg.get("sound.sample_rate").integer;
        if (_sampleRate < 8000 || _sampleRate > 48000) {
            throw new Exception("Audio sample rate must be 8000 to 48000 Hz.");
        }

        _volume = cfg.get("sound.volume").floating;
        if (_volume < 0.0 || _volume > 1.0) {
            throw new Exception("Volume must be 0.0 to 1.0.");
        }

        _outputFilename = cfg.get("sound.output_filename").str;
        _deviceIndex = cast(int)cfg.get("sound.device_index").integer;
    }

    @property
    public uint sampleRate() {
        return _sampleRate;
    }
}

module Interface.IAudioOut;

import App.Config;


public alias void delegate(immutable double[2] buffer) AudioBufferCallback;

public interface IAudioOut {
    public void queueSample(immutable double[2] buffer);
    public void destroy();
    @property public uint sampleRate();
}

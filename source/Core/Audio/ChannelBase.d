module Core.Audio.ChannelBase;

import Core.Audio.IChannel;


public abstract class ChannelBase : IChannel {
    protected ubyte _volume;
    protected bool _active;

    public void stop() {
        _active = false;
    }

    @property
        public ubyte volume() {
            return _volume;
        }

    @property
        public void volume(immutable ubyte newVolume) {
            _volume = newVolume;
        }

    @property
        public bool active() {
            return _active;
        }
}

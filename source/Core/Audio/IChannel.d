module Core.Audio.IChannel;


public interface IChannel {
    public void reset();
    public double cycle();
    public ubyte readIO(immutable ushort address);
    public void writeIO(immutable ushort address, immutable ubyte data);

    public void stop();
    @property public ubyte volume();
    @property public void volume(immutable ubyte newVolume);
    @property public bool active();
}

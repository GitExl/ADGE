module Core.IGameboyDevice;

import Core.Gameboy;


public interface IGameboyDevice {
    public void reset();
    public void attach(Gameboy);
    public void cycle();
}

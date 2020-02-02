module Core.Gameboy;

import std.stdio;

import Core.CPU;
import Core.MMU;
import Core.Timer;
import Core.Debugger;
import Core.Cart;
import Core.LCD;
import Core.Joypad;
import Core.BootROM;
import Core.APU;

import Config;


public enum GameboyMode : ubyte {
    CLASSIC,
    COLOR,
    SUPER,
    SUPER2,
}

private immutable uint CLOCKRATE_GMB = 4194304;
private immutable uint CLOCKRATE_CGB = 8388608;
private immutable uint CLOCKRATE_SGB = 4295454;
private immutable uint CLOCKRATE_SGB2 = 4194304;

private immutable double VIDEO_REFRESH_GMB = 59.727500;
private immutable double VIDEO_REFRESH_SGB = 61.167891;
private immutable double VIDEO_REFRESH_SGB2 = 59.727500;

public final class Gameboy {
    private GameboyMode _mode;

    private MMU _mmu;
    private CPU _cpu;
    private Timer _timer;
    private Cart _cart;
    private LCD _lcd;
    private APU _apu;
    private Debugger _dbg;
    private Joypad _joypad;
    private BootROM _bootrom;

    private int _clockRate;
    private double _videoRefreshRate;

    private bool _frameComplete;

    public this(Config cfg) {
        switch (cfg.get("gameboy.mode").str) {
            case "dmg":
            case "mgb":
                _mode = GameboyMode.CLASSIC;
                _clockRate = CLOCKRATE_GMB;
                _videoRefreshRate = VIDEO_REFRESH_GMB;
                break;
            case "gbc":
                _mode = GameboyMode.COLOR;
                _clockRate = CLOCKRATE_GMB;
                _videoRefreshRate = VIDEO_REFRESH_GMB;
                break;
            case "sgb":
                _mode = GameboyMode.SUPER;
                _clockRate = CLOCKRATE_SGB;
                _videoRefreshRate = VIDEO_REFRESH_SGB;
                break;
            case "sgb2":
                _mode = GameboyMode.SUPER2;
                _clockRate = CLOCKRATE_SGB2;
                _videoRefreshRate = VIDEO_REFRESH_SGB2;
                break;
            default:
                throw new Exception("Cannot instantiate unknown gameboy mode.");
        }

        _cpu = new CPU();
        _mmu = new MMU();
        _cart = new Cart();
        _timer = new Timer();
        _lcd = new LCD();
        _joypad = new Joypad();
        _apu = new APU();
        _bootrom = new BootROM("boot/" ~ cfg.get("gameboy.boot_rom").str ~ ".bin");
        _dbg = new Debugger();
        
        _cpu.attach(this);
        _mmu.attach(this);
        _cart.attach(this);
        _lcd.attach(this);
        _timer.attach(this);
        _joypad.attach(this);
        _apu.attach(this);
        _bootrom.attach(this);
        _dbg.attach(this);

        _timer.updateClockRate(_clockRate);

        reset();
    }

    public void executeFrame() {
        _frameComplete = false;
        while(1) {
            _cpu.cycle();
            if (_frameComplete) {
                break;
            }
        }
    }

    public void cycle() {
        _timer.cycle();
        _apu.cycle();
        _lcd.cycle();

        if (_lcd.vblankTriggered) {
            _frameComplete = true;
        }
    }

    public void loadCart(immutable string fileName) {
        reset();
        _cart.load(fileName);
        
        writefln("Loaded cart '%s' (%s).", _cart.title, _cart.licensee);
        if (_cart.isCGB) {
            if (_cart.isCGBOnly) {
                writeln("Requires Gameboy Color.");
            } else {
                writeln("Supports Gameboy Color.");
            }
        }
        if (_cart.isSGB) {
            writeln("Supports Super Gameboy.");
        }
    }

    public void reset() {
        _cpu.reset();
        _lcd.reset();
        _mmu.reset();
        _cart.reset();
        _timer.reset();
        _joypad.reset();
        _apu.reset();
        _bootrom.reset();
    }

    @property
    public int clockRate() {
        return _clockRate;
    }

    @property
    public double videoRefreshRate() {
        return _videoRefreshRate;
    }

    @property
    public CPU cpu() {
        return _cpu;
    }

    @property
    public MMU mmu() {
        return _mmu;
    }

    @property
    public LCD lcd() {
        return _lcd;
    }

    @property
    public Timer timer() {
        return _timer;
    }

    @property
    public Cart cart() {
        return _cart;
    }

    @property
    public Joypad joypad() {
        return _joypad;
    }

    @property
    public APU apu() {
        return _apu;
    }

    @property
    public Debugger dbg() {
        return _dbg;
    }

    @property
    public BootROM bootrom() {
        return _bootrom;
    }

    @property
    public GameboyMode mode() {
        return _mode;
    }
}
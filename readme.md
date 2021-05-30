# A D Gameboy Emulator (ADGE)

A gameboy emulator written in D.


## Usage

The emulator is configured through the `config.json` file. ROM files are loaded from the first command line argument.

Games that use RAM for saving game data will have their data written to a .ram file next to the ROM file.

Use the `A` and `S` for the A and B buttons, the arrow keys for the D-pad, right shift for select and enter for start.
The grave key (or tilde) will enable fast forward mode while held down.

The tab key will enter the debug mode. Entering a blank command will exit debug mode. For a list of debug commands
consult the Core\Debugger class in the source.

See the compatibility section for a long list of things that are not implemented and wont work.


## Configuration

The default configuration:

```json
  "gameboy": {
    "mode": "dmg",
    "boot_rom": "dmg",
    "fast_forward_frameskip": 6
  },
  "display": {
    "palette": "pocket",
    "border_horizontal": 3,
    "border_vertical": 2,
    "scale": 6,
    "vsync": true,
    "blur_frames": 2,
    "filter": "nearest"
  },
  "sound": {
    "sample_rate": 48000,
    "volume": 1.0,
    "highpass_filter": true,
    "buffer_size": 512,
    "output_filename": "",
    "device_index": 0
  },
```

### Gameboy

The `mode` setting can be `dmg` for a classic Gameboy, `mgb` for the Gameboy pocket and Light, `gbc` for the Gameboy
Color and `sgb` and `sgb2` for the Super Gameboy and Super Gameboy 2 respectively. Note though that there are currently
no Gameboy Color or Super Gameboy features implemented, so games targeting that hardware will not work. Also take care
to configure the proper boot ROM file for the selected mode. THese are located in the `boot` directory.

`fast_forward_frameskip` determines the number of frames to skip when fast forward is enabled. If your system is fast
enough you can configure it to skip rendering more frames, though beyond a certain point fast forwarding is limited by
your CPU speed.

### Display

Using the `palette` option you can select a palette JSON file from the `palette` directory to map Gameboy Classic
style colors to. The two border options determine how much room to leave around the display area. The border will be
drawn in the palette's specific border color.

`scale` sets the size at which the Gameboy display is rendered. `vsync` will sync emulation speed to your display's
refresh rate (even if that is more or less than 60Hz!), otherwise it will output frames at the appropriate speed for
the configured Gameboy mode. The `filter` option can be set to `nearest` or `linear` for a pixelated or smoothly
scaled display respectively.

`blur_frames` determines how many emulated frames to blur together to simulate the Gameboy display's slow pixel
response times. Many games make use of this display characteristic to simulate transparency by quickly toggling
graphics on or off.

### Sound

The `sample_rate` option is currently limited to 48000 Hz due to an SDL2 limitation. The `volume` option must be a value
between 0.0 and 1.0. The `buffer_size` is best left alone.

Enabling the `highpass_filter` option will apply a high pass filter to the audio just like the real Gameboy hardware
does.

If you want to output the raw rendered audio to a file, specify the `output_filename` option. The written file will
contain 16 bit signed integer samples in stereo at the configured sample rate.

Use the `device_index` option to specify the index of the sound device to use for playback. 0 is usually the default
device.

### Input

Input options exist but are currently not implemented.


## Compatibility

The emulator is designed to be cycle-accurate. It renders the display on a scanline basis so any game or demo relying
on mid-scanline effects will not display properly. Sound is emulated at 2 Mhz with samples averaged together to produce
the desired output samplerate.

The following memory bank controllers are currently not implemented so games using these will not work:

* `MMM01`
* `MBC3`
* `MBC5`
* `TAMA5`
* `HUC1`
* `HUC3`

Additionally, only Gameboy classic support is present. Any Gameboy Color games or games requiring Super Gameboy hardware
will fail to run.


## Known issues

* Display output timing is not entirely accurate enough for some games. Most games seem to work fine but some may
cause corruption or other glitches.
* Sprite prioarites are not always handled correctly, so some sprites may overlap areas they shouldn't.
* Sound output has pops and clicks because too many samples are output per second. This is related to the inaccurate display
timing.
* Many bugs and inaccuracies may lurk around in timing sensitive areas.
* Many odd behavours of the Gameboy hardware are not emulated.
* Performance is more than good enough on any kind of modern hardware, but could be better...

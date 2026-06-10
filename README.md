# GBCandy Nano

**Game Boy / Game Boy Color on Tang Nano 20K FPGA**

[中文文档](README_zh.md)

GBCandy Nano is an open-source FPGA Game Boy / Game Boy Color emulator running on the Sipeed Tang Nano 20K development board. It implements the complete Game Boy hardware logic — CPU, PPU, APU, Timer, and MBC Mapper — enabling original Game Boy games to run on FPGA.

## Features

- **Full LR35902 CPU** — Cycle-accurate Game Boy CPU with complete instruction set (including CB-prefix instructions)
- **PPU (Pixel Processing Unit)** — Background, window, and sprite rendering with 4-shade DMG palette / CGB color palette
- **APU (Audio Processing Unit)** — 4-channel audio (pulse ×2, wave, noise) with I2S output
- **Timer** — Complete DIV/TIMA/TMA/TAC register implementation
- **MBC Mapper** — MBC1/MBC3/MBC5 cartridge mapping support
- **OAM Bug Emulation** — Accurate reproduction of DMG hardware OAM corruption behavior
- **SDRAM Storage** — 64Mbit embedded SDRAM for ROM/VRAM/WRAM
- **IOSys ROM Loading** — Load game ROMs via SPI Flash / SD card
- **OSD Menu** — Press R+Start to toggle the on-screen display menu

## Branches

This repository provides two hardware configuration branches for different display and input setups:

### `main` branch — 720p HDMI + DS2 Controller

- **Video**: 720p (1280×720) HDMI output, 4× scaled GB 160×144 display
- **Input**: DualShock 2 controller
- **LED**: 6 onboard LED debug indicators
- **Use case**: Connect to HDMI monitor + DS2 controller

### `hdmi_lcd_480_640` branch — 480×640 + GBC Buttons

- **Video**: 480×640 VGA-resolution HDMI output
- **Input**: Direct GBC button connections (D-pad + A/B/Select/Start)
- **Use case**: Connect to small LCD screen + custom GBC button panel

## Hardware Requirements

- **FPGA Board**: Sipeed Tang Nano 20K (GW2AR-LV18QN88C8)
- **Storage**: Onboard 64Mbit SDRAM + SPI Flash + SD card
- **Audio**: Onboard MAX98357A I2S Class-D amplifier
- **Input**:
  - `main` branch: DualShock 2 controller
  - `hdmi_lcd_480_640` branch: GBC button panel
- **Display**: HDMI monitor or LCD screen

## Building & Flashing

### Prerequisites

- **Gowin IDE 1.9.9 Pro** (free license required)
- Tang Nano 20K development board

### Build

```bash
# Build using Gowin command-line tools
gw_sh build.tcl nano20k

# Or on Windows
buildall.bat
```

Build output: `impl/pnr/gbcandy_test.fs`

### Flash

1. Connect Tang Nano 20K to your computer via USB
2. Open Gowin Programmer
3. Select the `.fs` file
4. Flash to FPGA

## Project Structure

```
├── src/
│   ├── gbc_top.v                 # Top-level module
│   ├── gb_cpu.v                  # LR35902 CPU
│   ├── gb_apu.v                  # APU audio processing unit
│   ├── gb_timer.v                # Timer module
│   ├── gb_mbc.v                  # MBC Mapper
│   ├── gb_cart_ram.v             # Cartridge RAM
│   ├── gb_sdram_if.v             # SDRAM interface
│   ├── gb_oam_dp.v               # OAM dual-port RAM (Gowin DP BSRAM)
│   ├── oam_bug.v                 # OAM Bug emulator
│   ├── boot_rom.v                # Boot ROM
│   ├── CEGen.v                   # Clock enable generator
│   ├── gbc_hdmi.v                # HDMI output
│   ├── gbc_ppu.v                 # PPU output adapter
│   ├── gbc_rom_loader.v          # ROM loader
│   ├── apu_*.v                   # APU submodules
│   ├── gb_cpu_modules/           # CPU submodules
│   │   ├── alu.v                 # Arithmetic logic unit
│   │   ├── control.v             # Control unit
│   │   ├── ppu.v                 # PPU core
│   │   └── ...
│   ├── hdmi2/                    # HDMI output modules
│   ├── nano20k/                  # Board-level config & constraints
│   └── iosys/                    # IOSys ROM loading system
├── firmware/                     # RISC-V firmware (IOSys)
├── build.tcl                     # Gowin build script
└── buildall.bat                  # Windows batch build script
```

## Memory Map

| Address Range | Description |
|---------------|-------------|
| 0x0000-0x7FFF | ROM (cartridge, mapped via MBC) |
| 0x8000-0x9FFF | VRAM (8KB) |
| 0xA000-0xBFFF | Cartridge RAM |
| 0xC000-0xDFFF | WRAM (8KB DMG / 32KB GBC) |
| 0xE000-0xFDFF | Echo RAM (WRAM mirror) |
| 0xFE00-0xFE9F | OAM (sprite attribute memory) |
| 0xFF00-0xFF7F | I/O registers |
| 0xFF80-0xFFFE | HRAM |
| 0xFFFF | IE (interrupt enable) |

## Clock Architecture

| Clock | Frequency | Purpose |
|-------|-----------|---------|
| sys_clk | 27 MHz | System clock (crystal input) |
| mclk | 21.6 MHz | CPU/PPU clock domain |
| fclk | 86 MHz | SDRAM clock domain |
| hclk | 14.85 MHz | HDMI pixel clock (`main` branch) |
| hclk5 | 74.25 MHz | HDMI serial clock (`main` branch) |

The CPU uses CE (Clock Enable) division from 21.6 MHz to derive the standard Game Boy clock of ~4.194304 MHz.

## Test Status

### blargg CPU Tests
- **cpu_instrs**: ✅ Passed

### blargg DMG Sound Tests
- **01-registers**: ✅ Passed
- **02-len_ctr**: ✅ Passed
- **03-trigger**: ⚠️ Partial
- **04-sweep**: ⚠️ Partial

## Acknowledgments

This project stands on the shoulders of the following excellent open-source projects. Our deepest gratitude to all the original authors:

- **[SNESTang](https://github.com/nand2mario/snestang)** by nand2mario — The foundational framework for this project. GBCandy's SDRAM controller, HDMI output, IOSys ROM loading system, and Gowin DP BSRAM primitive wrappers all originate from SNESTang. Without SNESTang, there would be no GBCandy.

- **[VerilogBoy / FPGAMB0](https://github.com/f32organization/gb.fpga)** by Wenting Zhang (zephray) — Reference implementation for the Game Boy CPU (LR35902), PPU, and APU. GBCandy's CPU instruction set, PPU rendering logic, and APU audio channels are ported and adapted from VerilogBoy's architecture.

- **[HDMI](https://github.com/sameer/hdmi)** by Sameer Puri — FPGA implementation of the HDMI 1.4a specification, providing a complete solution for TMDS encoding, audio packets, and HDMI signal generation.

- **[PicoRV32](https://github.com/YosysHQ/picorv32)** by Claire Xenia Wolf — RISC-V processor core used in the IOSys system for ROM loading and OSD menu functionality.

- **[FatFs](http://elm-chan.org/fsw/ff/00index_e.html)** by ChaN — Embedded FAT file system for SD card file reading.

- **[Gameboy_MiSTer](https://github.com/MiSTer-devel/Gameboy_MiSTer)** — MiSTer Game Boy/GBC complete implementation, providing important reference for PPU timing and hardware behavior verification.

- **[epGB](https://github.com/ep209/epGB)** — Game Boy/GBC FPGA implementation, providing reference for CGB color mode and HDMA implementation.

- **[NESTang](https://github.com/nand2mario/nestang)** by nand2mario — NES implementation on Tang boards, providing reference for platform adaptation and toolchain.

## References

- [Pan Docs](https://gbdev.io/pandocs/) — Complete Game Boy hardware documentation
- [Game Boy Architecture](https://www.copetti.org/writings/consoles/game-boy/) — Game Boy architecture analysis
- [Gowin Semiconductor](https://www.gowinsemi.com/) — FPGA toolchain and documentation

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).

Some code in this project originates from other open-source projects and retains their respective licenses and attribution:

- SNESTang code: GPL v3
- VerilogBoy code: GPL v3
- HDMI module: BSD 3-Clause (Sameer Puri)
- PicoRV32: ISC (Claire Xenia Wolf)
- FatFs: FatFs License (ChaN)
- Gowin IP files: Copyright Gowin Semiconductor Corporation

## Author

Yulin Kuang

---

*GBCandy Nano — Game Boy on FPGA, with love.*

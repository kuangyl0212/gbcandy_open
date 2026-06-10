# GBCandy build script with SDRAM and IOSys support

set_device GW2AR-LV18QN88C8/I7 -device_version C
add_file src/nano20k/config.v
add_file -type cst "src/nano20k/gbc.cst"
add_file -type sdc "src/snestang.sdc"

# HDMI modules from snestang
add_file -type verilog "src/nano20k/gowin_pll_hdmi.v"
add_file -type verilog "src/nano20k/gowin_pll_snes.v"
add_file -type verilog "src/hdmi2/audio_clock_regeneration_packet.sv"
add_file -type verilog "src/hdmi2/audio_info_frame.sv"
add_file -type verilog "src/hdmi2/audio_sample_packet.sv"
add_file -type verilog "src/hdmi2/auxiliary_video_information_info_frame.sv"
add_file -type verilog "src/hdmi2/hdmi.sv"
add_file -type verilog "src/hdmi2/packet_assembler.sv"
add_file -type verilog "src/hdmi2/packet_picker.sv"
add_file -type verilog "src/hdmi2/serializer.sv"
add_file -type verilog "src/hdmi2/source_product_description_info_frame.sv"
add_file -type verilog "src/hdmi2/tmds_channel.sv"
add_file -type verilog "src/dual_clk_fifo.v"

# DS2 Controller modules
add_file -type verilog "src/dualshock_controller.v"
add_file -type verilog "src/controller_ds2.sv"

# SDRAM controller
add_file -type verilog "src/nano20k/sdram_nano.v"

# GB CPU module
add_file -type verilog "src/gb_cpu.v"
add_file -type verilog "src/gb_cpu_modules/common.v"
add_file -type verilog "src/gb_cpu_modules/alu.v"
add_file -type verilog "src/gb_cpu_modules/regfile.v"
add_file -type verilog "src/gb_cpu_modules/singlereg.v"
add_file -type verilog "src/gb_cpu_modules/control.v"
add_file -type verilog "src/gb_cpu_modules/ppu.v"
add_file -type verilog "src/gb_oam_dp.v"
# add_file -type verilog "src/gb_vram_dp.v"
# add_file -type verilog "src/gb_wram_dp.v"
# add_file -type verilog "src/gb_cgram.v"
add_file -type verilog "src/oam_bug.v"
add_file -type verilog "src/gb_cpu_modules/singleport_ram.v"
add_file -type verilog "src/dpram.v"

# IOSys modules - PicoRV32 softcore for OSD and ROM loading
add_file -type verilog "src/iosys/iosys.v"
add_file -type verilog "src/iosys/picorv32.v"
add_file -type verilog "src/iosys/simplespimaster.v"
add_file -type verilog "src/iosys/simpleuart.v"
add_file -type verilog "src/iosys/spi_master.v"
add_file -type verilog "src/iosys/spiflash.v"
add_file -type verilog "src/iosys/textdisp.v"
add_file -type verilog "src/iosys/gowin_dpb_menu.v"

# GB APU modules (VerilogBoy architecture)
add_file -type verilog "src/apu_clk_div.v"
add_file -type verilog "src/apu_vol_env.v"
add_file -type verilog "src/apu_length_ctr.v"
add_file -type verilog "src/apu_channel_mix.v"
add_file -type verilog "src/apu_square.v"
add_file -type verilog "src/apu_wave.v"
add_file -type verilog "src/apu_noise.v"
add_file -type verilog "src/gb_apu.v"
add_file -type verilog "src/gb_timer.v"

# GB Core
add_file -type verilog "src/CEGen.v"
add_file -type verilog "src/gb_sdram_if.v"
add_file -type verilog "src/gb_mbc.v"
add_file -type verilog "src/gb_cart_ram.v"
add_file -type verilog "src/gbc_top.v"
add_file -type verilog "src/uart_tx_V2.v"

set_option -output_base_name gbcandy_test
set_option -synthesis_tool gowinsynthesis
set_option -top_module gbc_top
set_option -verilog_std sysv2017
set_option -rw_check_on_ram 1
set_option -place_option 2
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_i2c_as_gpio 1
set_option -use_cpu_as_gpio 1
set_option -multi_boot 1

run all

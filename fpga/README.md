```
$ make -C fw && cp fw/bios.vh /tmp/
$ python3 rgb-tool.py ~/Downloads/parrot.jpg 128 128 > /tmp/parrot.dat
```
```
$ vivado -mode tcl -script flow.tcl
```
```
$ vivado -mode batch -source sim.tcl
```

Program FPGA and pulse reset
```
uart:~$ m64 fpga program /SD:/FPGA.BIN
uart:~$ m64 fpga write32 0x10000000 0x1
uart:~$ m64 fpga write32 0x10000000 0x0
```
Set grid color (to white) for parrot example
```
uart:~$ m64 fpga write32 0x20000010 0xffffff
```

## Misc
```
$ ffmpeg -i m64-hdmi.mkv -vf scale=-2:720 -c:v libx264 -crf 23 -c:a aac -movflags +faststart m64-hdmi.mp4

$ pactl list | grep MACRO
$ ffmpeg -f v4l2 -input_format mjpeg -framerate 30 -video_size 1920x1080 -i /dev/video0 -f pulse -ac 2 -ar 48000 -i alsa_input.usb-MACROSILICON_USB3.0_Video_04304933-02.analog-stereo -map 0:v -map 1:a -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -g 60 -c:a aac -b:a 192k -af aresample=async=1 -movflags +faststart out.mp4
```

## MCU to FPGA SPI protocol

- 16-bit command
- 32-bit address
- 8-bit dummy
- N x 32-bit data (total length given in command as well as byte strobe for last access, if write)

Bus register map
================

| 0x1000_0000 | System ctrl (resets) |
| 0x1000_0010 | OSD ctrl             |
| 0x1000_0100 | N64 Ctrlr #0         |
| 0x1000_0104 | N64 Ctrlr #1         |
| 0x1000_0108 | N64 Ctrlr #2         |
| 0x1000_010c | N64 Ctrlr #3         |
| 0x1001_0000 | RISC-V ROM           |
| 0x1002_0000 | OSD Screen RAM       |
| 0x1003_0000 | OSD Char RAM         |
| 0x3000_0000 | Scratch RAM          |

## On Screen Display (OSD)

- 64x32 characters one byte each 2KB screen RAM
- 128 16x16 characters in 4KB bitmap RAM

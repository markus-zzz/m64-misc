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
```

## MCU to FPGA SPI protocol

- 16-bit command
- 32-bit address
- 8-bit dummy
- N x 32-bit data (total length given in command as well as byte strobe for last access, if write)

## On Screen Display (OSD)

- 64x32 characters one byte each 2KB screen RAM
- 128 16x16 characters in 4KB bitmap RAM

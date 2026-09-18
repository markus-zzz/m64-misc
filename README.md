# ModRetro M64 Custom Firmware (WIP)

Here is an attempt at rolling custom firmware for the [ModRetro M64
console](https://modretro.com/products/m64) based on their open sourced
[schematics](https://support.modretro.com/en_us/articles/m64-open-source-files-ByrpukdUGg).

For details of the architecture study the schematics linked above but at a
birds eye view there is a `STM32H7A3ZIT6` Arm Cortex-M7 based MCU SoC from
STMicroelectronics and a `XCAU15P-2FFVB676E` Xilinx UltraScale+ FPGA. The MCU
is responsible for bring up and house keeping while the FPGA does the
emulation.

Here we will have the MCU run [Zephyr RTOS](https://www.zephyrproject.org/).

## Setup / build instructions

### Setup Zephyr

#### 1. venv + west (if not done yet)
```
python3 -m venv ~/.venvs/zephyr
source ~/.venvs/zephyr/bin/activate
pip install west
```

#### 2. bootstrap the workspace using your local manifest
```
cd .../m64-misc
west init -l mcu
west update            # clones Zephyr + only cmsis & hal_stm32
west zephyr-export
west packages pip --install
```

#### 3. ARM-only SDK
```
cd $(west topdir)/zephyr
west sdk install -t arm-zephyr-eabi
```

### Build the MCU firmware
```
source ~/.venvs/zephyr/bin/activate
cd .../m64-misc/mcu
west build -b m64 .
```

### Build the example FPGA bitstream
```
source .../Xilinx/2026.1/Vivado/settings64.sh
cd .../m64-misc/fpga
vivado -mode tcl -script flow.tcl
```

### Flash the firmware onto STM32

With your computer connected to the USB receptacle marked `power` on the back
of the M64 the first task is to put it in DFU mode. This is easiest
accomplished by holding down the menu button while pressing the power button
for about 15 seconds and then finally release the menu button. According to the
schematic pressing the power button for > 7.5s will activate the hard reset
circuitry (in practice I found it to take a bit longer). Coming out of reset
with both power button and menu button depressed will enter DFU mode.

Verify that DFU mode is entered

```
$ lsusb
...
Bus 001 Device 062: ID 0483:df11 STMicroelectronics STM Device in DFU Mode
```
```
$ dfu-util -l
...
Found DFU: [0483:df11] ver=0200, devnum=59, cfg=1, intf=0, path="1-5.1.3", alt=2, name="@OTP Memory   /0x08FFF000/01*1024 e", serial="336D396B3434"
Found DFU: [0483:df11] ver=0200, devnum=59, cfg=1, intf=0, path="1-5.1.3", alt=1, name="@Option Bytes   /0x5200201C/01*297 e", serial="336D396B3434"
Found DFU: [0483:df11] ver=0200, devnum=59, cfg=1, intf=0, path="1-5.1.3", alt=0, name="@Internal Flash   /0x08000000/256*08Kg", serial="336D396B3434"
```
> **WARNING: Proceeding beyond this point will erase the ModRetro firmware from the device - ESSENTIALLY MAKING IT USELESS!!!**

Flash the custom firmware onto the device
```
$ dfu-util -a 0 -s 0x08000000:leave -D build/zephyr/zephyr.bin
...
dfu-util: Warning: Invalid DFU suffix signature
dfu-util: A valid DFU suffix will be required in a future dfu-util release
Opening DFU capable USB device...
Device ID 0483:df11
Device DFU version 011a
Claiming USB DFU Interface...
Setting Alternate Interface #0 ...
Determining device status...
DFU state(2) = dfuIDLE, status(0) = No error condition is present
DFU mode device DFU version 011a
Device returned transfer size 1024
DfuSe interface name: "Internal Flash   "
Downloading element to address = 0x08000000, size = 102284
Erase   	[=========================] 100%       102284 bytes
Erase    done.
Download	[=========================] 100%       102284 bytes
Download done.
File downloaded successfully
Submitting leave request...
dfu-util: Error during download get_status
```

### Loading the FPGA

Zephyr is serving a shell over a USB virtual serial port - connect to it and
make the devices SD card mountable by the host computer
```
$ minicom -D /dev/ttyACM0
```
```
uart:~$ m64 sd unmount
[00:01:22.758,000] <inf> m64: SD unmounted from /SD:
unmounted
uart:~$ 
```
Do `lsblk` to find the SD card (exported as USB storage device) and mount it.
```
sudo mount /dev/sdXX /media/
```
Copy the FPGA bitstream to the SD card and unmount
```
sudo cp .../m64-misc/fpga/out/fpga.bin /media/
sudo umount /media
```
Back in the Zephyr shell do
```
uart:~$ m64 sd mount
[00:05:49.670,000] <inf> m64: SD mounted at /SD:
mounted at /SD:
uart:~$ m64 sd ls
  1311004 FPGA.BIN
uart:~$ m64 fpga /SD:/FPGA.BIN
programming...
[00:06:10.237,000] <inf> m64_fpga: INIT_B during clear (expect 0): 0
[00:06:10.241,000] <inf> m64_fpga: FPGA ready for bitstream (bit-bang)
[00:06:12.858,000] <inf> m64_fpga: clocked 1311004 bytes; INIT_B dipped during load: NO
[00:06:12.858,000] <inf> m64_fpga: FPGA configured: DONE high after 64 startup clocks
FPGA programmed from /SD:/FPGA.BIN
```
This particular FPGA bitstream will do nothing more than produce a square wave
on the `DATA` pin of the controller ports.

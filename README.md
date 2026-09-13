# 1. venv + west (if not done yet)
```
python3 -m venv ~/.venvs/zephyr
source ~/.venvs/zephyr/bin/activate
pip install west
```

# 2. bootstrap the workspace using your local manifest
```
cd /home/markus/work/repos/m64-misc
west init -l mcu
west update            # clones Zephyr + only cmsis & hal_stm32
west zephyr-export
west packages pip --install
```

# 3. ARM-only SDK
```
cd $(west topdir)/zephyr
west sdk install -t arm-zephyr-eabi
```

# 4. build
```
export ZEPHYR_BASE=$(west topdir)/zephyr
cd /home/markus/work/repos/m64-misc/mcu
west build -b m64 .
```


# Misc
```
zephyr/boards/st/nucleo_h7a3zi_q/nucleo_h7a3zi_q.dts
modules/hal/stm32/dts/st/h7/stm32h7a3z(g-i)txq-pinctrl.dtsi
```

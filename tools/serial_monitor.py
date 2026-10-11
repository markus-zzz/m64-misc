#!/usr/bin/env python3
"""
Interleaved serial monitor + MCU command driver for the ModRetro M64.

Connects to the MCU (/dev/ttyACM0) and the FPGA (/dev/ttyUSB0) serial ports
simultaneously and prints their output interleaved on the console, with each
line prefixed by a colored tag identifying its source.

Full MCU-driven workflow:

  0. Fresh start: reboot the MCU so every run begins from a clean state, then
     wait for the USB serial to re-enumerate and re-sync to the prompt:
         uart:~$ kernel reboot cold
  1. Unmount the SD on the MCU so the host sees it as USB mass storage:
         uart:~$ m64 sd unmount
  2. On the HOST: mount the SD (device resolved via fstab), copy the FPGA
     bitstream and the soft-CPU BIOS onto it, sync and unmount:
         mount ~/media/
         cp <fpga.bin>  ~/media/
         cp <bios.bin>  ~/media/
         sync
         umount ~/media/
  3. Re-mount the SD on the MCU and list it:
         uart:~$ m64 sd mount
         uart:~$ m64 sd ls
  4. Drive the FPGA bring-up command sequence (program, reset, download BIOS,
     release reset, set grid color).

The FPGA port is a passive monitor throughout. All traffic flows through each
spawn's `logfile_read` so output stays interleaved.

Usage:
    ./serial_monitor.py --fpga-bin ./out/fpga.bin --bios-bin ./out/bios.bin
    ./serial_monitor.py --skip-sd-copy ...   # skip SD copy, drive FPGA only

NOTE: the SD mount/copy/unmount steps assume `--mount-point` is configured in
fstab so the current user can `mount`/`umount` it without specifying a device
(e.g. an fstab entry with the `user` option). Each host command is printed
before it runs.

Press Ctrl-C to exit.
"""

import argparse
import os
import subprocess
import sys
import threading
import time

import pexpect
import serial
from pexpect import fdpexpect


# ANSI colors so the two streams are easy to tell apart.
RESET = "\033[0m"
COLORS = {
    "MCU": "\033[36m",   # cyan
    "FPGA": "\033[33m",  # yellow
    "HOST": "\033[32m",  # green
}

# Zephyr shell prompt. The default is "uart:~$ " (see README transcripts).
PROMPT = r"uart:~\$ "

# Per-command timeout (seconds). Programming / downloading can take a while,
# so this is generous; adjust with --cmd-timeout if needed.
DEFAULT_CMD_TIMEOUT = 60


class LabelWriter:
    """
    A file-like object suitable for pexpect's `logfile_read`.

    pexpect writes the raw bytes it reads into this object. We buffer the data
    per-source and emit it line-by-line, prefixing every completed line with a
    colored "[LABEL]" tag. Writes are serialized with a shared lock so lines
    from different sources never get mangled together.
    """

    _lock = threading.Lock()

    def __init__(self, label, out=sys.stdout, use_color=True):
        self.label = label
        self.out = out
        self._buf = ""
        color = COLORS.get(label, "") if use_color else ""
        reset = RESET if (use_color and color) else ""
        self._prefix = f"{color}[{label:>4}]{reset} "

    def write(self, data):
        # pexpect in bytes mode hands us bytes; decode leniently.
        if isinstance(data, bytes):
            data = data.decode("utf-8", errors="replace")
        self._buf += data
        # Emit all complete lines; keep any trailing partial line buffered.
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            line = line.rstrip("\r")
            self._emit(line)

    def note(self, text):
        """Emit an out-of-band annotation line under this label."""
        self._emit(text)

    def _emit(self, line):
        with LabelWriter._lock:
            self.out.write(f"{self._prefix}{line}\n")
            self.out.flush()

    def flush(self):
        self.out.flush()


# A standalone writer for host-side annotations (not tied to a spawn).
_HOST_WRITER = None


def host_note(text):
    if _HOST_WRITER is not None:
        _HOST_WRITER.note(text)
    else:
        with LabelWriter._lock:
            sys.stdout.write(f"[HOST] {text}\n")
            sys.stdout.flush()


BY_ID_DIR = "/dev/serial/by-id"


def resolve_mcu_device(spec):
    """Resolve the MCU serial device to a *stable* path when possible.

    The problem this solves: on `kernel reboot` the USB CDC-ACM device drops
    and re-enumerates. If something still holds the old /dev/ttyACMn node open
    at that instant, the kernel assigns the next free name (ttyACM0 -> ttyACM1),
    so reopening a hard-coded ttyACMn fails. The /dev/serial/by-id/ symlink is
    derived from the USB serial number and therefore stays constant across
    re-enumeration, so we prefer it.

    `spec` may be:
      * a /dev/serial/by-id/... path  -> returned as-is (already stable)
      * a /dev/ttyACMn path           -> mapped to its by-id symlink if one
                                         exists, else returned unchanged
      * "auto"                        -> auto-detect the ZEPHYR ModRetro M64
                                         by-id symlink

    Returns a device path (string). The returned by-id path is itself a
    symlink that the OS re-resolves on every open(), so passing it to
    open_port() after a reboot transparently follows the device.
    """
    # Explicit by-id path: trust it.
    if spec != "auto" and spec.startswith(BY_ID_DIR):
        return spec

    # Build a map of real tty -> by-id symlink, plus the Zephyr/ModRetro one.
    byid_for_tty = {}
    zephyr_byid = None
    try:
        for name in os.listdir(BY_ID_DIR):
            link = os.path.join(BY_ID_DIR, name)
            try:
                target = os.path.realpath(link)
            except OSError:
                continue
            byid_for_tty[target] = link
            if "ZEPHYR" in name or "ModRetro" in name:
                zephyr_byid = link
    except FileNotFoundError:
        byid_for_tty = {}

    if spec == "auto":
        if zephyr_byid:
            return zephyr_byid
        # Fall back to the first ttyACM* if auto-detection found no symlink.
        if os.path.exists("/dev/ttyACM0"):
            return "/dev/ttyACM0"
        return "/dev/ttyACM0"

    # A concrete ttyACMn path: prefer its stable by-id symlink if present.
    real = os.path.realpath(spec)
    return byid_for_tty.get(real, spec)


def open_port(device, baud):
    """Open a serial port and return a (serial, fdpexpect.fdspawn) pair.

    `device` may be a by-id symlink; the OS resolves it at open() time so the
    same path keeps working after the USB device re-enumerates.
    """
    ser = serial.Serial(device, baudrate=baud, timeout=0)
    spawn = fdpexpect.fdspawn(ser.fileno(), encoding=None)
    return ser, spawn


def monitor_loop(label, spawn, stop_event):
    r"""
    Passive drain: continuously pump bytes so that `logfile_read` fires.

    A never-matching pattern with a short timeout keeps data flowing into
    `logfile_read`, which does the actual printing.

    NOTE: the sentinel must be `pexpect.TIMEOUT`, not a regex like r"\Z". In
    bytes mode (`encoding=None`) the `\Z` anchor matches the empty string at
    the end of pexpect's buffer *immediately*, so `expect` returns without ever
    calling `read_nonblocking` - no bytes are pulled from the port and
    `logfile_read` never fires. `pexpect.TIMEOUT` genuinely never matches, so
    `expect` keeps reading (feeding `logfile_read`) until the timeout elapses.
    """
    while not stop_event.is_set():
        try:
            spawn.expect(pexpect.TIMEOUT, timeout=0.2)
        except pexpect.TIMEOUT:
            pass
        except pexpect.EOF:
            _annotate(spawn, "EOF - port closed")
            break
        except OSError as exc:
            _annotate(spawn, f"serial error: {exc}")
            break


def _drain(spawn, settle=0.15):
    """Consume whatever is currently in the serial/pexpect buffer.

    pexpect's `expect` searches the *cumulative* buffer, so a prompt left over
    from a previous command would make the next `expect(PROMPT)` return
    immediately (matching stale text) instead of waiting for the new command to
    finish. Draining first guarantees the subsequent prompt match corresponds
    to the command we are about to send. `logfile_read` still prints anything
    drained here, so no output is lost.
    """
    deadline = time.monotonic() + settle
    while time.monotonic() < deadline:
        try:
            # Grab any pending bytes; non-empty read extends the window a bit.
            data = spawn.read_nonblocking(size=4096, timeout=0.05)
            if data:
                deadline = time.monotonic() + settle
        except pexpect.TIMEOUT:
            break
        except (pexpect.EOF, OSError):
            break
    # Reset pexpect's match buffer so no stale prompt lingers.
    try:
        spawn.buffer = spawn.buffer[:0]
    except Exception:
        pass


def mcu_send(spawn, cmd, cmd_timeout, desc=None):
    """Send one MCU shell command and wait for the prompt to return.

    The flow is: drain any stale buffer, send the command, wait for the shell
    to echo it back (so we're synchronised past our own input), then wait for
    the prompt that marks completion. Matching the echo first prevents an
    earlier prompt sitting in the buffer from satisfying the prompt match
    prematurely and firing the next command too soon (which overran the
    device's shell RX ring buffer).

    Returns True on success, False on timeout/EOF/error.
    """
    prompt = PROMPT.encode()
    if desc:
        _annotate(spawn, f">>> {desc}: {cmd}")
    else:
        _annotate(spawn, f">>> {cmd}")
    try:
        # Clear anything stale (e.g. the prompt we just synced to) first.
        _drain(spawn)
        spawn.send(cmd.encode() + b"\r")
        # Synchronise on the command echo so the following prompt match can
        # only be the one that terminates *this* command.
        try:
            spawn.expect_exact(cmd.encode(), timeout=cmd_timeout)
        except pexpect.TIMEOUT:
            # Echo may be disabled or coalesced; fall through to prompt wait.
            pass
        spawn.expect(prompt, timeout=cmd_timeout)
        return True
    except pexpect.TIMEOUT:
        _annotate(spawn, f"WARNING: timeout waiting for prompt after: {cmd}")
    except pexpect.EOF:
        _annotate(spawn, "EOF during command - aborting")
    except OSError as exc:
        _annotate(spawn, f"serial error during '{cmd}': {exc}")
    return False


def run_host(cmd_list):
    """Run a host command, streaming its output under the [HOST] label.

    `cmd_list` is a list of argv tokens (no shell). Returns the exit code.
    """
    host_note("$ " + " ".join(cmd_list))
    try:
        proc = subprocess.run(
            cmd_list,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:
        host_note(f"command not found: {exc}")
        return 127
    for line in proc.stdout.splitlines():
        host_note(line)
    if proc.returncode != 0:
        host_note(f"(exit code {proc.returncode})")
    return proc.returncode


def sd_copy_workflow(spawn, args):
    """Unmount SD on MCU, copy bins from host, remount. Returns True on ok."""
    mount_point = os.path.expanduser(args.mount_point)

    # 1. Unmount on the MCU so the host sees the mass-storage device.
    if not mcu_send(spawn, "m64 sd unmount", args.cmd_timeout,
                    "Expose SD as USB mass storage"):
        return False

    # Give the host a moment to enumerate the new block device.
    time.sleep(args.enumerate_delay)

    # 2a. Mount on the host (mount point assumed to exist, per fstab setup).
    if run_host(["mount", mount_point]) != 0:
        host_note("mount failed - aborting SD copy")
        return False

    copied_ok = True
    try:
        # 2b. Copy both binaries.
        for src in (args.fpga_bin, args.bios_bin):
            if not os.path.isfile(src):
                host_note(f"source not found: {src} - aborting")
                copied_ok = False
                break
            if run_host(["cp", src, mount_point]) != 0:
                host_note(f"copy failed: {src}")
                copied_ok = False
                break
        # 2c. Flush buffers to the card before unmounting.
        if copied_ok:
            run_host(["sync"])
    finally:
        # 2d. Always try to unmount so we don't leave the card busy.
        if run_host(["umount", mount_point]) != 0:
            host_note("WARNING: umount failed; SD may still be mounted on host")

    if not copied_ok:
        return False

    # 3. Re-mount on the MCU and list contents.
    if not mcu_send(spawn, "m64 sd mount", args.cmd_timeout, "Remount SD on MCU"):
        return False
    mcu_send(spawn, "m64 sd ls", args.cmd_timeout, "List SD contents")
    return True


def fpga_sequence(spawn, args):
    """Drive the FPGA bring-up commands using the on-SD basenames."""
    fpga_name = os.path.basename(args.fpga_bin)
    bios_name = os.path.basename(args.bios_bin)

    commands = [
        (f"m64 fpga program /SD:/{fpga_name}", "Load default design into FPGA"),
        ("m64 fpga write32 0x10000000 1",      "Assert reset for soft CPU"),
        (f"m64 fpga write 0x10010000 /SD:/{bios_name}",
         "Download soft CPU firmware"),
        ("m64 fpga write32 0x10000000 0",      "De-assert reset for soft CPU"),
        ("m64 fpga write32 0x20000010 0xffffff", "Grid color set to white"),
    ]
    for cmd, desc in commands:
        if not mcu_send(spawn, cmd, args.cmd_timeout, desc):
            _annotate(spawn, "aborting FPGA sequence")
            return False
    return True


def sync_prompt(spawn, timeout=10):
    """Nudge the shell with CR and wait for the prompt. Returns True on sync.

    Drains any stale buffer first so the prompt we match is the one produced
    by *our* CR, not leftover text from before (which would make this report
    success without the shell actually being responsive).
    """
    prompt = PROMPT.encode()
    try:
        _drain(spawn)
        spawn.send(b"\r")
        spawn.expect(prompt, timeout=timeout)
        return True
    except pexpect.TIMEOUT:
        _annotate(spawn, "WARNING: no shell prompt seen")
        return False
    except pexpect.EOF:
        _annotate(spawn, "EOF while waiting for prompt")
        return False
    except OSError as exc:
        _annotate(spawn, f"serial error while waiting for prompt: {exc}")
        return False


def reconnect_mcu(old_ser, old_spawn, args, use_color, deadline):
    """Close the stale MCU port and reopen it after a reboot re-enumeration.

    The USB CDC-ACM device drops and re-enumerates on `kernel reboot`, so the
    old file descriptor becomes invalid. Retry opening args.mcu until it comes
    back (or `deadline`, a time.monotonic() value, is reached).

    Returns (ser, spawn) on success, or (None, None) on failure. The fresh
    spawn reuses the MCU LabelWriter so output stays under the [ MCU] label.
    """
    label_writer = getattr(old_spawn, "logfile_read", None)

    # Tear down the stale handles.
    try:
        if old_spawn is not None:
            old_spawn.close()
    except Exception:
        pass
    try:
        if old_ser is not None:
            old_ser.close()
    except OSError:
        pass

    host_note(f"waiting for MCU ({args.mcu}) to re-enumerate after reboot...")
    while time.monotonic() < deadline:
        # Re-resolve every attempt: the by-id symlink is recreated by udev
        # once the re-enumerated device is ready, and will point at whatever
        # ttyACMn the kernel assigned (ttyACM0, ttyACM1, ...).
        device = resolve_mcu_device(args.mcu)
        try:
            ser, spawn = open_port(device, args.mcu_baud)
        except (serial.SerialException, OSError):
            time.sleep(0.5)
            continue
        # Reattach the existing writer so the [ MCU] stream is continuous.
        spawn.logfile_read = label_writer or LabelWriter(
            "MCU", use_color=use_color)
        host_note(f"MCU re-opened on {device}")
        return ser, spawn

    host_note("ERROR: MCU did not re-enumerate before timeout")
    return None, None


def command_loop(spawn, ser, stop_event, args, use_color, mcu_holder):
    """
    Drive the MCU. The very first action is a `kernel reboot` so every run
    starts from a clean MCU state. After the reboot we reopen the (re-
    enumerated) serial port, re-sync to the prompt, run the SD copy workflow,
    then the FPGA bring-up sequence. Finally fall back to passive monitoring.

    `mcu_holder` is a dict shared with main() so that main's cleanup always
    closes whatever serial object is current (it changes across the reboot).
    """
    # Sync to the current prompt before rebooting.
    sync_prompt(spawn)

    # 1. Fresh start: reboot the MCU.
    _annotate(spawn, f">>> Fresh start: kernel reboot {args.reboot_type}")
    try:
        spawn.send(f"kernel reboot {args.reboot_type}".encode() + b"\r")
    except OSError as exc:
        _annotate(spawn, f"serial error sending reboot: {exc}")

    # The port drops here; give the device a moment to actually reset.
    time.sleep(args.reboot_settle)

    # 2. Reconnect to the re-enumerated USB serial device.
    deadline = time.monotonic() + args.reconnect_timeout
    ser, spawn = reconnect_mcu(ser, spawn, args, use_color, deadline)
    if spawn is None:
        return
    mcu_holder["ser"] = ser
    mcu_holder["spawn"] = spawn

    # 3. Re-sync to the fresh prompt.
    if not sync_prompt(spawn, timeout=args.reconnect_timeout):
        _annotate(spawn, "could not sync to prompt after reboot; monitoring")
        monitor_loop("MCU", spawn, stop_event)
        return

    # 4. SD copy workflow.
    if not args.skip_sd_copy:
        if not sd_copy_workflow(spawn, args):
            _annotate(spawn, "SD copy workflow failed; not running FPGA sequence")
            monitor_loop("MCU", spawn, stop_event)
            return
    else:
        _annotate(spawn, "skipping SD copy (--skip-sd-copy)")

    # 5. FPGA bring-up sequence.
    if not stop_event.is_set():
        fpga_sequence(spawn, args)

    _annotate(spawn, "<<< sequence complete; monitoring")
    monitor_loop("MCU", spawn, stop_event)


def _annotate(spawn, text):
    """Write an annotation via the spawn's LabelWriter if present."""
    lw = getattr(spawn, "logfile_read", None)
    if isinstance(lw, LabelWriter):
        lw.note(text)
    else:
        with LabelWriter._lock:
            sys.stdout.write(text + "\n")
            sys.stdout.flush()


def main():
    global _HOST_WRITER

    parser = argparse.ArgumentParser(
        description="Interleaved serial monitor + MCU command driver for the "
                    "ModRetro M64 (MCU + FPGA)."
    )
    parser.add_argument("--mcu", default="auto",
                        help="MCU serial device. 'auto' (default) resolves the "
                             "stable /dev/serial/by-id/ symlink for the ZEPHYR "
                             "ModRetro M64 so the port is followed across "
                             "reboot re-enumeration. May also be an explicit "
                             "/dev/serial/by-id/... or /dev/ttyACMn path (a "
                             "ttyACMn path is still mapped to its by-id symlink "
                             "when one exists).")
    parser.add_argument("--fpga", default="/dev/ttyUSB0",
                        help="FPGA serial device (default: /dev/ttyUSB0)")
    parser.add_argument("--mcu-baud", type=int, default=115200,
                        help="MCU baud rate (default: 115200)")
    parser.add_argument("--fpga-baud", type=int, default=115200,
                        help="FPGA baud rate (default: 115200)")

    parser.add_argument("--fpga-bin", default="fpga.bin",
                        help="Path to the FPGA bitstream to copy to the SD "
                             "(default: fpga.bin)")
    parser.add_argument("--bios-bin", default="bios.bin",
                        help="Path to the soft-CPU BIOS to copy to the SD "
                             "(default: bios.bin)")
    parser.add_argument("--mount-point", default="~/media",
                        help="Host mount point for the SD, resolved via fstab "
                             "(default: ~/media)")
    parser.add_argument("--enumerate-delay", type=float, default=2.0,
                        help="Seconds to wait after MCU unmount for the host "
                             "to enumerate the block device (default: 2.0)")

    parser.add_argument("--cmd-timeout", type=int, default=DEFAULT_CMD_TIMEOUT,
                        help="Per-command prompt timeout in seconds "
                             f"(default: {DEFAULT_CMD_TIMEOUT})")
    parser.add_argument("--reboot-type", default="cold",
                        choices=("cold", "warm"),
                        help="Argument to `kernel reboot` issued first "
                             "(default: cold)")
    parser.add_argument("--reboot-settle", type=float, default=2.0,
                        help="Seconds to wait after sending reboot before "
                             "trying to reopen the MCU port (default: 2.0)")
    parser.add_argument("--reconnect-timeout", type=float, default=30.0,
                        help="Max seconds to wait for the MCU USB serial to "
                             "re-enumerate after reboot (default: 30.0)")
    parser.add_argument("--skip-sd-copy", action="store_true",
                        help="Skip the SD unmount/copy/remount; drive FPGA only")
    parser.add_argument("--no-color", action="store_true",
                        help="Disable ANSI colored labels")
    args = parser.parse_args()

    use_color = not args.no_color
    _HOST_WRITER = LabelWriter("HOST", use_color=use_color)

    # Resolve the MCU spec ('auto' or a ttyACMn path) to a stable by-id symlink
    # for the initial open. args.mcu is left as the original spec so the
    # post-reboot reconnect can re-resolve it against the fresh symlink.
    mcu_device = resolve_mcu_device(args.mcu)
    if mcu_device != args.mcu:
        _HOST_WRITER.note(f"MCU resolved: {args.mcu} -> {mcu_device}")

    ports = [
        ("MCU", mcu_device, args.mcu_baud),
        ("FPGA", args.fpga, args.fpga_baud),
    ]

    sers = {}
    spawns = {}
    for label, device, baud in ports:
        try:
            ser, spawn = open_port(device, baud)
        except (serial.SerialException, OSError) as exc:
            sys.stderr.write(f"Failed to open {label} on {device}: {exc}\n")
            for s in sers.values():
                s.close()
            sys.exit(1)
        spawn.logfile_read = LabelWriter(label, use_color=use_color)
        sers[label] = ser
        spawns[label] = spawn
        print(f"Opened {label:>4} on {device} @ {baud} baud")

    print("Driving MCU workflow; monitoring FPGA... press Ctrl-C to stop.\n")

    stop_event = threading.Event()
    threads = []

    # Shared holder so cleanup closes whatever MCU serial is current (the
    # command driver swaps it out across the initial reboot).
    mcu_holder = {"ser": sers["MCU"], "spawn": spawns["MCU"]}

    # FPGA: always passive monitor.
    t_fpga = threading.Thread(
        target=monitor_loop, args=("FPGA", spawns["FPGA"], stop_event),
        daemon=True,
    )
    t_fpga.start()
    threads.append(t_fpga)

    # MCU: command driver.
    t_mcu = threading.Thread(
        target=command_loop,
        args=(spawns["MCU"], sers["MCU"], stop_event, args, use_color,
              mcu_holder),
        daemon=True,
    )
    t_mcu.start()
    threads.append(t_mcu)

    try:
        while any(t.is_alive() for t in threads):
            time.sleep(0.1)
    except KeyboardInterrupt:
        print("\nStopping...")
    finally:
        stop_event.set()
        for t in threads:
            t.join(timeout=1.0)
        # Close the FPGA port and the current MCU port (may have been swapped).
        to_close = [sers["FPGA"], mcu_holder.get("ser")]
        for ser in to_close:
            if ser is None:
                continue
            try:
                ser.close()
            except OSError:
                pass


if __name__ == "__main__":
    main()

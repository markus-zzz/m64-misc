#!/usr/bin/env python3
"""
Dump two symbol streams from the GTH TX simulation VCD into separate text files
for manual correlation:

  1. tmds_symbols_0 (the encoder reference), one entry per change, expanded to
     one line per pixel-clock symbol period so the two files advance at the same
     rate.
  2. Symbols extracted from the serialized data lane hdmi_tx_p[2], recovered by
     using the transmitted TMDS clock (hdmi_clk_p) as the timing reference:
     each negedge->negedge span = one 10-bit symbol; divide the span into 10
     equal slices and sample the lane at each slice center, LSB-first.

No alignment, latency search, or rotation is applied -- the raw streams are
written so you can correlate them yourself.

Usage:
  python3 dump_tmds.py [path/to/hdmi_gth_tx.vcd] [out_prefix]

Outputs:
  <prefix>_ref.txt   : time_ns  symbol_bin  symbol_hex   (tmds_symbols_0)
  <prefix>_wire.txt  : time_ns  symbol_bin  symbol_hex   (from hdmi_tx_p[2])

Lane note: hdmi_tx_p[2] carries tmds_symbols[0] because
  gtwiz_userdata_tx = {word_tx[3], word_tx[0], word_tx[1], word_tx[2]}
  (GT bit2 -> pin J5 -> TMDS D0). Adjust LANE_BIT / REF_ID for other lanes.
"""
import sys
import re

DEFAULT_VCD = "sim_proj/hdmi_sim.sim/sim_1/behav/xsim/hdmi_gth_tx.vcd"

CLK_ID = "("     # hdmi_clk_p
TXP_ID = "&"     # hdmi_tx_p [2:0]
REF_ID = "/"     # tmds_symbols_0 [9:0]
RDY_ID = "*"     # tx_ready
LANE_BIT = 2     # bit of hdmi_tx_p carrying tmds_symbols[0]

SYMBOL_BITS = 10
SETTLE_AFTER_READY_FS = 1_000_000_000  # start 1 us after tx_ready (fs; 1us=1e9fs)

# The hdmi_clk_p negedge sits a fixed number of UIs into the 10-UI symbol period
# (the TMDS clock symbol 0000011111 has its falling edge 5 UI in). So a 10-UI
# sampling window that STARTS at the negedge straddles two adjacent data symbols
# -- fine while the data is constant, but at symbol transitions it mixes half of
# one symbol with half of the next. To recover whole symbols we shift the
# sampling window by this many UIs so it aligns to the true symbol boundary.
# Set to 0 to sample directly from the negedge (raw, boundary-straddling).
WINDOW_SHIFT_UI = 5


def parse_vcd(path):
    t = 0
    clk_edges, txp_edges, ref_changes = [], [], []
    t_ready = None
    last_clk = last_lane = None
    in_defs = True
    with open(path) as f:
        for line in f:
            if in_defs:
                if line.startswith("$enddefinitions"):
                    in_defs = False
                continue
            if not line:
                continue
            c = line[0]
            if c == "#":
                t = int(line[1:])
            elif c == "b":
                m = re.match(r"b([01xzXZ]+)\s+(\S+)", line)
                if not m:
                    continue
                bits, ident = m.group(1), m.group(2)
                if ident == TXP_ID:
                    v = bits.zfill(LANE_BIT + 1)[::-1][LANE_BIT]
                    if v != last_lane:
                        txp_edges.append((t, 1 if v == "1" else 0))
                        last_lane = v
                elif ident == REF_ID and set(bits) <= set("01"):
                    ref_changes.append((t, int(bits, 2)))
            elif c in "01xz":
                ident = line[1:].strip()
                if ident == CLK_ID:
                    v = 1 if c == "1" else 0
                    if v != last_clk:
                        clk_edges.append((t, v))
                        last_clk = v
                elif ident == RDY_ID and c == "1" and t_ready is None:
                    t_ready = t
    return clk_edges, txp_edges, ref_changes, t_ready


def lane_at(txp_edges, t, hint):
    i = hint
    n = len(txp_edges)
    while i + 1 < n and txp_edges[i + 1][0] <= t:
        i += 1
    while i > 0 and txp_edges[i][0] > t:
        i -= 1
    return txp_edges[i][1], i


def negedges(clk_edges, t_min):
    out = []
    for i in range(1, len(clk_edges)):
        if clk_edges[i][1] == 0 and clk_edges[i - 1][1] == 1 and clk_edges[i][0] >= t_min:
            out.append(clk_edges[i][0])
    return out


def extract_wire(clk_edges, txp_edges, t_min):
    """One symbol per hdmi_clk_p negedge->negedge span: divide by 10, sample
       each slice center, LSB-first. Skip spans that are not ~1 symbol wide."""
    negs = negedges(clk_edges, t_min)
    if len(negs) < 3:
        return []
    spans = sorted(negs[i + 1] - negs[i] for i in range(len(negs) - 1))
    median = spans[len(spans) // 2]
    lo, hi = median * 0.8, median * 1.2
    out = []
    hint = 0
    for i in range(len(negs) - 1):
        t0, t1 = negs[i], negs[i + 1]
        span = t1 - t0
        if span < lo or span > hi:
            continue
        ui = span / SYMBOL_BITS
        # Shift the sampling window so it aligns to the true symbol boundary
        # instead of starting mid-symbol at the negedge.
        base = t0 + WINDOW_SHIFT_UI * ui
        val = 0
        for b in range(SYMBOL_BITS):
            tc = int(base + (b + 0.5) * ui)   # center of UI b, LSB-first
            bit, hint = lane_at(txp_edges, tc, hint)
            val |= (bit & 1) << b
        out.append((t0, val))
    return out


def ref_stream(ref_changes, t_min, t_max, period_fs):
    """Expand the event-based tmds_symbols_0 into one entry per symbol period so
       it advances at the same one-symbol-per-line rate as the wire stream."""
    if not ref_changes:
        return []
    # Value holder function.
    times = [t for t, _ in ref_changes]
    vals = [v for _, v in ref_changes]

    def val_at(t):
        lo, hi = 0, len(times) - 1
        if t < times[0]:
            return None
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if times[mid] <= t:
                lo = mid
            else:
                hi = mid - 1
        return vals[lo]

    out = []
    t = t_min
    while t <= t_max:
        v = val_at(t)
        if v is not None:
            out.append((t, v))
        t += period_fs
    return out


def write_stream(path, stream):
    with open(path, "w") as f:
        f.write("# time_ns    bin(LSB..MSB)  hex\n")
        for t, v in stream:
            # bin printed LSB-first (bit0 leftmost) to match on-wire order.
            b = "".join(str((v >> i) & 1) for i in range(SYMBOL_BITS))
            f.write(f"{t/1e6:12.3f}  {b}  {v:03x}\n")


def main():
    vcd = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_VCD
    prefix = sys.argv[2] if len(sys.argv) > 2 else "tmds"
    print(f"Parsing {vcd} ...")
    clk_edges, txp_edges, ref_changes, t_ready = parse_vcd(vcd)
    if t_ready is None:
        print("tx_ready never asserted; nothing to dump.")
        return 1
    t_min = t_ready + SETTLE_AFTER_READY_FS
    print(f"  tx_ready @ ~{t_ready/1e6:.1f} ns; dumping from ~{t_min/1e6:.1f} ns")

    wire = extract_wire(clk_edges, txp_edges, t_min)
    if not wire:
        print("No wire symbols extracted.")
        return 1
    t_max = wire[-1][0]
    # Symbol period from the wire itself (median negedge spacing).
    negs = negedges(clk_edges, t_min)
    spans = sorted(negs[i + 1] - negs[i] for i in range(len(negs) - 1))
    period = spans[len(spans) // 2]

    ref = ref_stream(ref_changes, t_min, t_max, period)

    write_stream(f"{prefix}_wire.txt", wire)
    write_stream(f"{prefix}_ref.txt", ref)
    print(f"  wrote {prefix}_wire.txt ({len(wire)} symbols)")
    print(f"  wrote {prefix}_ref.txt  ({len(ref)} symbols)")
    print("  Correlate manually, e.g.:")
    print(f"    paste {prefix}_ref.txt {prefix}_wire.txt | less")
    return 0


if __name__ == "__main__":
    sys.exit(main())

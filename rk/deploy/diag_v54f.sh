#!/bin/sh
# V54f (CFG_VER=0x5403) on-board diagnostic.
# Reads the rgb_to_yuv422_quad input/output taps plus link state.
# Usage: sh diag_v54f.sh

BUS=9
ADDR=0x1a

rd() {
    v=$(i2cget -y $BUS $ADDR "$1" 2>/dev/null)
    printf "  0x%-3s = %s\n" "$1" "$v"
}

echo "== CFG_VER (expect 0xa9=0x03 0xaa=0x54) =="
rd 0xa9
rd 0xaa

echo "== rgb2yuv INPUT pix0  {0x0f=tog 0x0e=in_b 0x0d=in_g 0x0c=in_r} =="
rd 0x0c
rd 0x0d
rd 0x0e
rd 0x0f

echo "== rgb2yuv OUTPUT pair0 {0xff=cr 0xfe=y1 0xfd=cb 0xfc=y0} =="
rd 0xfc
rd 0xfd
rd 0xfe
rd 0xff

echo "== encoder / stitch status =="
rd 0xa3
rd 0xa4
rd 0xa5
rd 0xa6
rd 0xe4
rd 0xe5
rd 0xef

echo "== frame counters =="
rd 0xd0
rd 0xe1
rd 0xe2

echo ""
echo "How to read the taps:"
echo "  in_r/in_g/in_b all ~equal and out_cb/out_cr ~0x80  -> source is greyscale"
echo "  out_cb/out_cr ~0x00                                -> rgb2yuv clip bug"
echo "  in_* plausible but out_cb/out_cr stuck             -> rgb2yuv arithmetic bug"
echo "  out_* plausible (cb/cr ~0x80..0xA0)                -> chroma lost AFTER rgb2yuv"

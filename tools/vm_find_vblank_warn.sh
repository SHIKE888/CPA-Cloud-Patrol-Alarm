#!/bin/bash
SDK=/home/uisrc/mlk-sdk-3576-v1.1.0
grep -rn "vblank need" "$SDK/kernel-6.1/drivers/media/platform/rockchip/cif/" 2>/dev/null | head -20
grep -rn "cur %d us\|cur %llu us\|1000us" "$SDK/kernel-6.1/drivers/media/platform/rockchip/cif/" 2>/dev/null | head -20

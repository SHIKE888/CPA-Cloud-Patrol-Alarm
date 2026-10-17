#!/bin/bash
SDK=/home/uisrc/mlk-sdk-3576-v1.1.0
sed -n '1600,1685p' "$SDK/kernel-6.1/drivers/media/platform/rockchip/cif/capture.c"

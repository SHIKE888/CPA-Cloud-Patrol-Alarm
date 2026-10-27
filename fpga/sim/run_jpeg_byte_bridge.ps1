# jpeg_byte_bridge 逐字节比对仿真
#   .\run_jpeg_byte_bridge.ps1
# 模块内联在 jpeg_encoder_top.v 末尾，所以编译整个 jpeg 目录 + 异步 FIFO。
$s = "$env:USERPROFILE\oss-cad-suite"
$env:PATH = "$s\bin;$s\lib;" + $env:PATH
$env:YOSYSHQ_ROOT = $s

Set-Location $PSScriptRoot

$j = "../uisrc/01_rtl/jpeg"
$common = @(
    "$j/jpeg_encoder_top.v",
    "$j/jpeg_linebuf.v",
    "$j/jpeg_dct2d.v",
    "$j/jpeg_quant_zz.v",
    
    "$j/jpeg_recip_pipe.v", "$j/jpeg_huff_enc.v",
    "$j/jpeg_bitpack.v",
    "$j/jpeg_headers.v",
    "$j/jpeg_lossless_enc.v",
    "$j/jpeg_qtable_ram.v",
    "$j/jpeg_range.v",
    "../uisrc/03_ip/al_fifo/fifo_32b_async_2.v"
)

iverilog -g2005 -I "$j" -o tb_jpeg_byte_bridge.vvp tb_jpeg_byte_bridge.v @common
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAILED"; exit 1 }
vvp tb_jpeg_byte_bridge.vvp

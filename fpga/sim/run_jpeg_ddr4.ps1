# DDR 读侧 + 4 引擎全链路仿真
#   .\run_jpeg_ddr4.ps1
$s = "$env:USERPROFILE\oss-cad-suite"
$env:PATH = "$s\bin;$s\lib;" + $env:PATH
$env:YOSYSHQ_ROOT = $s

Set-Location $PSScriptRoot

$j = "../uisrc/01_rtl/jpeg"
$src = @(
    "$j/jpeg_encoder_top.v",
    "$j/jpeg_linebuf.v",
    "$j/jpeg_dct2d.v",
    "$j/jpeg_quant_zz.v",
    "$j/jpeg_recip_pipe.v",
    "$j/jpeg_huff_enc.v",
    "$j/jpeg_bitpack.v",
    "$j/jpeg_headers.v",
    "$j/jpeg_lossless_enc.v",
    "$j/jpeg_qtable_ram.v",
    "$j/jpeg_range.v",
    "$j/jpeg_seg_merge4.v",
    # yuv32_to_quad 已并入 jpeg_encoder_top.v 末尾 (TD 会冲掉工程文件列表条目)
    "../uisrc/03_ip/al_fifo/fifo_32b_async_2.v"
)

iverilog -g2005 -I "$j" -o tb_jpeg_ddr4.vvp tb_jpeg_ddr4.v @src
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAILED"; exit 1 }
vvp tb_jpeg_ddr4.vvp

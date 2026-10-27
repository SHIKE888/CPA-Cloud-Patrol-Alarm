# jpeg_enc_if 逐字比对仿真
#   .\run_jpeg_enc_if.ps1
#
# ⚠ jpeg_enc_if / jpeg_byte_bridge 已【内联】在 jpeg_encoder_top.v 末尾
#   （已打开的 TD 工程用内存里的旧文件列表，新增 .v 会被当成 black box，
#     且 TD 退出保存时会把手工加的条目冲掉）。
#   所以这里编译整个 jpeg 目录 + 异步 FIFO，而不是单独编某个模块文件。
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

iverilog -g2005 -I "$j" -o tb_jpeg_enc_if.vvp tb_jpeg_enc_if.v @common
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAILED"; exit 1 }
vvp tb_jpeg_enc_if.vvp

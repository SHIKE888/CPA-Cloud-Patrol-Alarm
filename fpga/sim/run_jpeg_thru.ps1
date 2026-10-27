# jpeg_encoder_top 真实吞吐测量 (clk/MCU)
#   .\run_jpeg_thru.ps1        # 有损 (DCT/SOF0)
#   .\run_jpeg_thru.ps1 1      # 无损 (DPCM/SOF3)
param(
    [int]$LL = 0
)
$s = "$env:USERPROFILE\oss-cad-suite"
$env:PATH = "$s\bin;$s\lib;" + $env:PATH
$env:YOSYSHQ_ROOT = $s

Set-Location $PSScriptRoot

$j = "../uisrc/01_rtl/jpeg"
# ★ 必须放进变量再传: PowerShell 会把字面量 -Ptb_... 当成自己的参数解析并拆碎
$pdef = "-Ptb_jpeg_thru.LL=$LL"
iverilog -g2005 -I "$j" $pdef -o tb_jpeg_thru.vvp `
    tb_jpeg_thru.v `
    "$j/jpeg_encoder_top.v" `
    "$j/jpeg_linebuf.v" `
    "$j/jpeg_dct2d.v" `
    "$j/jpeg_quant_zz.v" `
    "$j/jpeg_recip_pipe.v" `
    "$j/jpeg_huff_enc.v" `
    "$j/jpeg_bitpack.v" `
    "$j/jpeg_headers.v" `
    "$j/jpeg_lossless_enc.v" `
    "$j/jpeg_qtable_ram.v" `
    "$j/jpeg_range.v" `
    "../uisrc/03_ip/al_fifo/fifo_32b_async_2.v"
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAILED"; exit 1 }

vvp tb_jpeg_thru.vvp

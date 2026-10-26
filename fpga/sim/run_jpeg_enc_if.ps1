# jpeg_enc_if 逐字比对仿真的编译+运行
#   .\run_jpeg_enc_if.ps1
$s = "$env:USERPROFILE\oss-cad-suite"
$env:PATH = "$s\bin;$s\lib;" + $env:PATH
$env:YOSYSHQ_ROOT = $s

Set-Location $PSScriptRoot
iverilog -g2005 -o tb_jpeg_enc_if.vvp `
    tb_jpeg_enc_if.v `
    ../uisrc/01_rtl/jpeg/jpeg_enc_if.v `
    ../uisrc/03_ip/al_fifo/fifo_32b_async_2.v
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAILED"; exit 1 }

vvp tb_jpeg_enc_if.vvp

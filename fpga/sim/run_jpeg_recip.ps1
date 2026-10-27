# jpeg_recip_pipe 穷举验证 (量化倒数表 22 级流水长除法)
#   .\run_jpeg_recip.ps1
$s = "$env:USERPROFILE\oss-cad-suite"
$env:PATH = "$s\bin;$s\lib;" + $env:PATH
$env:YOSYSHQ_ROOT = $s

Set-Location $PSScriptRoot

$j = "../uisrc/01_rtl/jpeg"

iverilog -g2005 -o tb_jpeg_recip.vvp `
    tb_jpeg_recip.v `
    "$j/jpeg_recip_pipe.v"
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAILED"; exit 1 }

vvp tb_jpeg_recip.vvp

# dual_stitch 仿真 (双目同时采集 + 整行乒乓 + 左右拼接)
#   .\run_dual_stitch.ps1
$s = "$env:USERPROFILE\oss-cad-suite"
$env:PATH = "$s\bin;$s\lib;" + $env:PATH
$env:YOSYSHQ_ROOT = $s

Set-Location $PSScriptRoot

$d = "../uisrc/01_rtl/dual"
$f = "../uisrc/03_ip/al_fifo"

iverilog -g2005 -o tb_dual_stitch.vvp `
    tb_dual_stitch.v `
    "$d/sensor_sync_start.v" `
    "$f/fifo_32b_async_2.v"
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAILED"; exit 1 }

vvp tb_dual_stitch.vvp

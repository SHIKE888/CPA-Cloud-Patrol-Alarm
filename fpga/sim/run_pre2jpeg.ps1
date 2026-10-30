# 预处理 -> RGB2YUV -> 4 引擎 JPEG -> 段合并 -> 字节桥 -> CSI-2 接缝台架
#   判据: RESULT : PASS  (ERR yuv/user/last 全 0, segcnt = 4*H)
#   产物: pre2jpeg.jpg  ->  python verify_jpeg.py pre2jpeg.jpg --w 512 --h 32
param([string]$Log = "run_pre2jpeg.log")
$s = "$env:USERPROFILE\oss-cad-suite"
$env:PATH = "$s\bin;$s\lib;" + $env:PATH
$env:YOSYSHQ_ROOT = $s
Set-Location $PSScriptRoot

$j = "../uisrc/01_rtl/jpeg"
$pp = "../uisrc/01_rtl/preproc"
$src = @(Get-ChildItem "$j/*.v" | ForEach-Object { $_.FullName })
$src += "$PSScriptRoot/../uisrc/01_rtl/csi2_frame_tx.v"
$src += "$PSScriptRoot/../uisrc/03_ip/al_fifo/fifo_32b_async_2.v"
$src += "$PSScriptRoot/../uisrc/03_ip/mipi_dsi/rgb_to_yuv422_quad.v"
$src += "$pp/preproc_post.v"

& iverilog -g2005 -I "$j" -I "$pp" -o tb_pre2jpeg.vvp tb_pre2jpeg.v @src
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAILED"; exit 1 }
Write-Host "=== running (log -> $Log) ..."
$t0 = Get-Date
& vvp tb_pre2jpeg.vvp *> $Log
Write-Host ("=== elapsed {0:n1} s" -f ((Get-Date) - $t0).TotalSeconds)
Get-Content $Log | Select-String 'RESULT|ERR |LINES|MERGED|ENG by|BRIDGE|TIMEOUT|source done' |
    ForEach-Object { $_.Line }

# 全幅台架: 4 引擎 x 960x1080 -> 4:1 段合并 -> 字节桥 -> CSI-2 变长组包器
#   用法:  .\run_tb_wd_full.ps1              (3840x1080 全幅)
#          .\run_tb_wd_full.ps1 -W 512 -H 32 (快速自检, 期望 6007B)
#   ⚠ 不要用 Tee-Object 记日志: 它会逐行刷盘, 把 vvp 拖到 100 倍慢。
param(
    [int]$W = 3840,
    [int]$H = 1080,
    [string]$Log = "run_full.log"
)
$s = "$env:USERPROFILE\oss-cad-suite"
$env:PATH = "$s\bin;$s\lib;" + $env:PATH
$env:YOSYSHQ_ROOT = $s
Set-Location $PSScriptRoot

if (-not (Test-Path "tb_wd_full.v")) { & "$PSScriptRoot\gen_tb_wd_full.ps1" }

$j = "../uisrc/01_rtl/jpeg"
$src = @(Get-ChildItem "$j/*.v" | ForEach-Object { $_.FullName })
$src += "$PSScriptRoot/../uisrc/01_rtl/csi2_frame_tx.v"
$src += "$PSScriptRoot/../uisrc/03_ip/al_fifo/fifo_32b_async_2.v"

& iverilog -g2005 -I "$j" -o tb_wd_full.vvp `
    -P tb_wd_full.W1=$W -P tb_wd_full.H=$H `
    -P tb_wd_full.MS_MODE=1 -P tb_wd_full.MS_ONE_SHOT=0 `
    -P tb_wd_full.WD_EN_FLUSH=0 -P tb_wd_full.WD_EN_SOFT=0 `
    -P tb_wd_full.WD_MAX=8000000 -P tb_wd_full.WD_USE_PROG=1 `
    tb_wd_full.v @src
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAILED"; exit 1 }
Write-Host "=== running ${W}x${H} (log -> $Log) ..."
$t0 = Get-Date
& vvp tb_wd_full.vvp *> $Log
Write-Host ("=== elapsed {0:n1} s, exit={1}" -f ((Get-Date) - $t0).TotalSeconds, $LASTEXITCODE)
Get-Content $Log | Select-String 'MERGED|PIXEL PATH|ERR  px|ENG by|ENG in|WORDS|TXBYTES|BRIDGE|TIMEOUT|\[WD\]' |
    ForEach-Object { $_.Line }

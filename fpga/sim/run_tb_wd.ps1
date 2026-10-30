# tb_wd —— 4 引擎 + 4:1 段合并 + 字节桥 + CSI-2 变长组包器 全链台架
#   判据: MERGED 6007 bytes / segcnt=19 / ENG by 1303,1394,1303,1392
#   参数: MS_MODE=1 复刻板上"只 rst_rel"的 m_start (V53b 修复后的接法)
$s = "$env:USERPROFILE\oss-cad-suite"
$env:PATH = "$s\bin;$s\lib;" + $env:PATH
$env:YOSYSHQ_ROOT = $s

Set-Location $PSScriptRoot

# ⚠ iverilog 14 的 -P 必须写成 "-P tb.param=val"(空格分隔), "-Pxxx" 会被当文件名
$j = "../uisrc/01_rtl/jpeg"
$src = @(Get-ChildItem "$j/*.v" | ForEach-Object { $_.FullName })
$src += "$PSScriptRoot/../uisrc/01_rtl/csi2_frame_tx.v"
$src += "$PSScriptRoot/../uisrc/03_ip/al_fifo/fifo_32b_async_2.v"

& iverilog -g2005 -I "$j" -o tb_wd.vvp `
    -P tb_wd.MS_MODE=1 -P tb_wd.MS_ONE_SHOT=0 `
    -P tb_wd.WD_EN_FLUSH=0 -P tb_wd.WD_EN_SOFT=0 `
    -P tb_wd.WD_MAX=8000000 -P tb_wd.WD_USE_PROG=1 `
    tb_wd.v @src
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAILED"; exit 1 }
vvp tb_wd.vvp

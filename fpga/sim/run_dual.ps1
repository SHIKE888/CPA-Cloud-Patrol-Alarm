#=============================================================================
# run_dual.ps1 -- one-shot entry for the dual-CSI simulations (Windows/iverilog)#
#   .\run_dual.ps1 dual    source select + per-channel isolation
#   .\run_dual.ps1 chain   crop + scheduler end-to-end (tuser/tlast/valid)
#   .\run_dual.ps1 regdb   0xDB register + version
#   .\run_dual.ps1 full    LP-free RX chain regression
#   .\run_dual.ps1 all     everything
#
# NOTE: keep this file pure ASCII. PowerShell 5.1 reads .ps1 as ANSI and any
#       UTF-8 Chinese here breaks the parser.
#
# Requires OSS CAD Suite (iverilog) at %USERPROFILE%\oss-cad-suite
#=============================================================================
param([string]$Target = "dual")

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$s = Join-Path $env:USERPROFILE "oss-cad-suite"
if (-not (Test-Path (Join-Path $s "bin\iverilog.exe"))) {
    Write-Host "!! iverilog not found at $s\bin" -ForegroundColor Red
    exit 1
}
$env:PATH = "$s\bin;$s\lib;" + $env:PATH
$env:YOSYSHQ_ROOT = $s

$RTL = Join-Path $here "..\uisrc"
$JPEG = Join-Path $RTL  "01_rtl\jpeg"
$CORR = Join-Path $RTL  "03_ip\ui_csi_raw\ui_image_correction.v"
$LPFREE = Join-Path $RTL  "03_ip\mipi_csi_lpfree"

$LPSRC = @("csi_rx_byte_align.v", "csi_rx_word_align.v", "csi_rx_word_gear_box.v",
    "csi_rx_packet_handler.v", "csi_rx_10bit_unpack.v", "csi_rx_vid2stream.v",
    "csi_rx_hdr_ecc.v", "mipi_sfifo.v") | ForEach-Object { Join-Path $LPFREE $_ }

$script:failed = 0

function Run-Sim([string]$title, [string]$tb, [string[]]$srcs) {
    Write-Host ""
    Write-Host "================ $title ================" -ForegroundColor Cyan
    $vvp = "$tb.vvp"
    $ivargs = @("-g2005", "-I", $JPEG, "-o", $vvp, (Join-Path $here "$tb.v")) + $srcs
    & iverilog @ivargs 2>&1 | ForEach-Object { "  $_" }
    if (-not (Test-Path $vvp)) {
        Write-Host "  !! compile failed" -ForegroundColor Red
        $script:failed++
        return
    }
    $out = & vvp $vvp 2>&1
    $out | ForEach-Object { $_ }
    if (($out -join "`n") -match "PASS") {
        Write-Host "  ==> PASS" -ForegroundColor Green
    }
    else {
        Write-Host "  ==> FAIL" -ForegroundColor Red
        $script:failed++
    }
}

switch ($Target) {
    "dual" { Run-Sim "tb_dual_src : source select / per-channel isolation" "tb_dual_src" @($CORR) }
    "sched" { Run-Sim "tb_dual_sched : alternating-frame scheduler"        "tb_dual_sched" @((Join-Path $RTL "01_rtl\dual\dual_frame_sched.v")) }
    "chain" { Run-Sim "tb_dual_chain : crop + sched end-to-end (tuser/tlast)" "tb_dual_chain" @($CORR, (Join-Path $RTL "01_rtl\dual\dual_frame_sched.v")) }
    "regdb" { Run-Sim "tb_reg_db   : 0xDB register + version 0x4700"        "tb_reg_db"  @((Join-Path $JPEG "jpeg_regfile.v")) }
    "full" { Run-Sim "tb_csi_full : LP-free RX chain regression"           "tb_csi_full" $LPSRC }
    "all" {
        Run-Sim "tb_dual_src : source select / per-channel isolation" "tb_dual_src" @($CORR)
        Run-Sim "tb_dual_sched : alternating-frame scheduler"        "tb_dual_sched" @((Join-Path $RTL "01_rtl\dual\dual_frame_sched.v"))
        Run-Sim "tb_dual_chain : crop + sched end-to-end (tuser/tlast)" "tb_dual_chain" @($CORR, (Join-Path $RTL "01_rtl\dual\dual_frame_sched.v"))
        Run-Sim "tb_reg_db   : 0xDB register + version 0x4700"        "tb_reg_db"  @((Join-Path $JPEG "jpeg_regfile.v"))
        Run-Sim "tb_csi_full : LP-free RX chain regression"           "tb_csi_full" $LPSRC
    }
    default { Write-Host "usage: .\run_dual.ps1 [dual|regdb|full|all]" }
}

Write-Host ""
if ($script:failed -eq 0) { Write-Host "ALL SIMULATIONS PASSED" -ForegroundColor Green }
else { Write-Host "$($script:failed) simulation(s) FAILED" -ForegroundColor Red; exit 1 }

# run_jpeg_sim.ps1 -- JPEG 编码器端到端仿真回归
#
# 用法:
#   .\tools\run_jpeg_sim.ps1                      # 跑默认尺寸集合
#   .\tools\run_jpeg_sim.ps1 -Sizes "64x16","1920x1080"
#
# 每轮: 生成 Python 参考 -> iverilog 编译 -> vvp 跑 -> 逐字节比对
# 判据: 只能看"逐字节相同", 不能只看长度或帧数 (长度相同但内容错过)

param(
    [string[]]$Sizes = @("64x16", "128x32", "160x24", "192x16", "320x40",
                         "640x48", "960x120", "1280x72", "1920x24", "1920x48",
                         "1920x96", "1920x216"),
    [switch]$StopOnFail
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# oss-cad-suite (iverilog)
$s = "$env:USERPROFILE\oss-cad-suite"
$env:PATH = "$s\bin;$s\lib;" + $env:PATH
$env:YOSYSHQ_ROOT = $s

$src   = "fpga\uisrc\01_rtl\jpeg"
$files = @(
    "$src\jpeg_dct2d.v", "$src\jpeg_quant_zz.v", "$src\jpeg_bitpack.v",
    "$src\jpeg_huff_enc.v", "$src\jpeg_headers.v", "$src\jpeg_linebuf.v",
    "$src\jpeg_encoder_top.v", "$src\jpeg_qtable_ram.v"
)

$fail = 0
foreach ($sz in $Sizes) {
    $parts = $sz -split 'x'
    $w = [int]$parts[0]
    $h = [int]$parts[1]

    python tools\gen_jpeg_e2e.py $w $h 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output ("{0,-12} GEN FAIL" -f $sz)
        $fail++
        continue
    }

    $out = & iverilog -g2005 -o fpga\sim\tb_jpeg_e2e.vvp -I $src -I fpga\sim `
                      fpga\sim\tb_jpeg_e2e.v @files 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Output ("{0,-12} COMPILE FAIL: {1}" -f $sz, $out)
        $fail++
        continue
    }

    Push-Location fpga\sim
    $r = (vvp tb_jpeg_e2e.vvp 2>&1 | Select-String 'RTL:|TIMEOUT').Line
    Pop-Location

    $cmp = python tools\cmp_jpeg.py 2>&1
    $ok  = $LASTEXITCODE -eq 0
    if (-not $ok) { $fail++ }

    Write-Output ("{0,-12} {1}  [{2}]" -f $sz, $cmp, $r)
    if (-not $ok -and $StopOnFail) { break }
}

Write-Output ""
if ($fail -eq 0) {
    Write-Output "ALL PASS ($($Sizes.Count) sizes, byte-identical to jpeg_ref.py)"
} else {
    Write-Output "$fail size(s) FAILED"
    exit 1
}

# 生成不同 PKT_BYTES 的 e2e tb 并跑 iverilog
param([int[]]$Pkts = @(32, 64, 1024))
$root = 'c:\Users\shike\Desktop\csi2rk2hdmi\08_csi2rk_mipi_imx415'
$s = "$env:USERPROFILE\oss-cad-suite"
$env:PATH = "$s\bin;$s\lib;" + $env:PATH
$env:YOSYSHQ_ROOT = $s
$src = "$root\fpga\uisrc\01_rtl"
$jl = @(
    "$src\csi2_frame_tx.v",
    "$src\jpeg\jpeg_dct2d.v", "$src\jpeg\jpeg_quant_zz.v", "$src\jpeg\jpeg_bitpack.v",
    "$src\jpeg\jpeg_huff_enc.v", "$src\jpeg\jpeg_headers.v", "$src\jpeg\jpeg_linebuf.v",
    "$src\jpeg\jpeg_lossless_enc.v", "$src\jpeg\jpeg_encoder_top.v", "$src\jpeg\jpeg_qtable_ram.v"
)
foreach ($pk in $Pkts) {
    $tb = "$root\fpga\sim\_tb_p$pk.v"
    $v = Get-Content "$root\fpga\sim\tb_jpeg_csi2_e2e.v" -Raw -Encoding UTF8
    $v = $v -replace 'parameter integer PKT\s*=\s*\d+;', "parameter integer PKT = $pk;"
    $v = $v -replace 'module tb_jpeg_csi2_e2e', "module tb_p$pk"
    [System.IO.File]::WriteAllText($tb, $v, (New-Object System.Text.UTF8Encoding($false)))
    $vvp = "$root\fpga\sim\_tb_p$pk.vvp"
    & iverilog -g2005 -o $vvp -I "$src\jpeg" -I "$root\fpga\sim" $tb @jl 2>&1 | Select-Object -First 3
    Push-Location "$root\fpga\sim"
    $out = vvp "_tb_p$pk.vvp" 2>&1 | Select-String 'CSI2:|RESULT|DIFF|TIMEOUT'
    Pop-Location
    $out | ForEach-Object { $_.Line }
    Remove-Item $tb, $vvp -ErrorAction SilentlyContinue
}

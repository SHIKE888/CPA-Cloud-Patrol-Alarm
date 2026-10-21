# 反压回归: 多组停顿图案跑编码器, 输出到 _r.log
$root = 'c:\Users\shike\Desktop\csi2rk2hdmi\08_csi2rk_mipi_imx415'
$s = "$env:USERPROFILE\oss-cad-suite"
$env:PATH = "$s\bin;$s\lib;" + $env:PATH
$env:YOSYSHQ_ROOT = $s
$src = "$root\fpga\uisrc\01_rtl"
Set-Location "$root\fpga\sim"

& iverilog -g2005 -o tb_es.vvp -I "$src\jpeg" -I . tb_enc_stall.v `
    "$src\jpeg\jpeg_dct2d.v" "$src\jpeg\jpeg_quant_zz.v" "$src\jpeg\jpeg_bitpack.v" `
    "$src\jpeg\jpeg_huff_enc.v" "$src\jpeg\jpeg_headers.v" "$src\jpeg\jpeg_linebuf.v" `
    "$src\jpeg\jpeg_lossless_enc.v" "$src\jpeg\jpeg_encoder_top.v" "$src\jpeg\jpeg_qtable_ram.v" 2>&1 |
Select-Object -First 6

$log = @()
foreach ($t in @(@(0, 0), @(40, 20), @(20, 5), @(64, 40), @(8, 4), @(4, 2))) {
    $log += "--- STALL=$($t[0]) SLEN=$($t[1]) ---"
    $log += (& vvp tb_es.vvp "+STALL=$($t[0])" "+SLEN=$($t[1])" 2>&1 | Select-String 'RESULT|TIMEOUT|DIFF')
}
$log | ForEach-Object { $_ }

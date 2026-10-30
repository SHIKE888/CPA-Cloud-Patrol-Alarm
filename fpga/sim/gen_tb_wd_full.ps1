# 由 tb_wd.v 生成 tb_wd_full.v (真实分辨率 3840x1080, 4 引擎各 960x1080)
#   - W1/H 改成 parameter, 便于 -P 覆盖
#   - ★ W4 在 tb_wd.v 里是硬编码 128, 必须跟着 W1/4 走, 否则分组/比对全错
#   - 等待判据用握手计数 n_rd32 = 每引擎 32b word 数 = (W1/4)*H/2 = W1*H/8
#     (x_wl 只有 16 位, 全幅 7680 还行但语义是 64b word, 别混用)
#   - 超时从 250000 提到 3000000 拍 (全幅一帧约 1.22M 拍)
#   - -FastSrc: 把 r_clk 从 105.2MHz 提到 147.5MHz = 板上 dbuf 读侧真实速率。
#     目的: 台架默认的源比编码慢 (52.6 组/us < 57.8 组/us), FIFO 永不溢出,
#     所以测不到板上那个 ovf=1。提到 147.5MHz 后灌入 73.8 组/us > 57.8,
#     与板上一模一样, 才能验证"全局反压是否会防住溢出"。
param([switch]$FastSrc)
$sim = $PSScriptRoot
$t = [System.IO.File]::ReadAllText("$sim\tb_wd.v", [System.Text.Encoding]::UTF8)

$t = $t.Replace('module tb_wd;', 'module tb_wd_full;')
$t = $t.Replace('    localparam integer W1   = 512;', '    parameter  integer W1   = 3840;')
$t = $t.Replace('    localparam integer W4   = 128;', '    parameter  integer W4   = W1/4;')
$t = $t.Replace('    localparam integer H    = 32;', '    parameter  integer H    = 1080;')
$t = $t.Replace('        wait ((x_wl[0] == W1*H/4/4) && (x_wl[1] == W1*H/4/4) &&',
    '        wait ((n_rd32[0] == W1*H/8) && (n_rd32[1] == W1*H/8) &&')
$t = $t.Replace('              (x_wl[2] == W1*H/4/4) && (x_wl[3] == W1*H/4/4));',
    '              (n_rd32[2] == W1*H/8) && (n_rd32[3] == W1*H/8));')
$t = $t.Replace('        wait (cyc >= 250000);', '        wait (cyc >= 3000000);')
if ($FastSrc) {
    # 9.504ns(105.2MHz) -> 6.780ns(147.5MHz), 与板上 dbuf 读侧 S_pclkx1 一致
    $t = $t.Replace('#4.752 r_clk = ~r_clk', '#3.390 r_clk = ~r_clk')
    if ($t -notmatch '#3\.390 r_clk') { Write-Host "WARN: FastSrc 替换失败" -ForegroundColor Red }
}
$t = $t.Replace("if (rst_n && (H <= 8) && g_enc[0].u_e.enc_mcu >= 24 && g_enc[0].u_e.u_huff.state == 3'd1) begin",
    "if (1'b0 && rst_n && g_enc[0].u_e.enc_mcu >= 24) begin")

[System.IO.File]::WriteAllText("$sim\tb_wd_full.v", $t, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "generated tb_wd_full.v  ($((Get-Item "$sim\tb_wd_full.v").Length) bytes)"
Select-String -Path "$sim\tb_wd_full.v" -Pattern '^module|parameter  integer|wait \(\(n_rd32|wait \(cyc|1.b0 && rst_n' |
ForEach-Object { "$($_.LineNumber): $($_.Line.Trim())" }
# 把 yuv32_to_quad 模块并入 jpeg_encoder_top.v 末尾
#   原因: TD 重写工程文件列表时会冲掉手工加入的 <File> 条目,
#   本工程既有规避做法 = 把辅助模块并入已登记的 jpeg_encoder_top.v
#   (jpeg_enc_if / jpeg_byte_bridge 就是这么处理的)
$ErrorActionPreference = 'Stop'
$dir = 'c:\Users\shike\Desktop\csi2rk2hdmi\08_csi2rk_mipi_imx415\fpga\uisrc\01_rtl\jpeg'
$enc = New-Object Text.UTF8Encoding($false)

$dstPath = Join-Path $dir 'jpeg_encoder_top.v'
$srcPath = Join-Path $dir 'yuv32_to_quad.v'

$dst = [IO.File]::ReadAllText($dstPath, [Text.Encoding]::UTF8)
$src = [IO.File]::ReadAllText($srcPath, [Text.Encoding]::UTF8)

if ($dst -match 'module\s+yuv32_to_quad') {
    Write-Host "jpeg_encoder_top.v 里已有 yuv32_to_quad, 跳过"
    return
}

$idx = $src.IndexOf('module yuv32_to_quad')
if ($idx -lt 0) { throw 'yuv32_to_quad.v 里找不到 module 定义' }

$body = $src.Substring($idx)

$header = @"


/*===========================================================================
 *  ★ 2026-10-28: 下面的 yuv32_to_quad 原本是独立文件 yuv32_to_quad.v。
 *    并进本文件的原因不是风格, 而是工程约束:
 *    TD 退出/保存时会重写 fpga_prj.al / syn_1/fpga_prj.prj 的 <File> 列表,
 *    手工加的条目会被冲掉 -> 综合报 HDL-8007 "yuv32_to_quad is a black box"。
 *    jpeg_enc_if / jpeg_byte_bridge 当初也是因为这个才放在本文件末尾。
 *==========================================================================*/

"@

[IO.File]::WriteAllText($dstPath, $dst + $header + $body, $enc)
Write-Host "已并入 jpeg_encoder_top.v, 新增 $($header.Length + $body.Length) 字符"

Remove-Item $srcPath -Force
Write-Host "已删除独立文件 yuv32_to_quad.v"

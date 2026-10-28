# 把 yuv32_to_quad.v 登记进工程文件清单（.prj / .al）
$ErrorActionPreference = 'Stop'
$root = 'c:\Users\shike\Desktop\csi2rk2hdmi\08_csi2rk_mipi_imx415'

function Add-Entry {
    param([string]$Path, [string]$Prefix)

    $txt = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ($txt -match 'yuv32_to_quad\.v') {
        Write-Host "已存在, 跳过: $Path"
        return
    }

    $anchor = @"
            <File Path="$Prefix/uisrc/01_rtl/jpeg/jpeg_seg_merge4.v">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&R" Val="true"/>
                    <Attr Name="BelongTo" Val="design_1"/>
                    <Attr Name="CompileOrder" Val="102"/>
                </FileInfo>
            </File>
"@

    $add = @"
            <File Path="$Prefix/uisrc/01_rtl/jpeg/jpeg_seg_merge4.v">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&R" Val="true"/>
                    <Attr Name="BelongTo" Val="design_1"/>
                    <Attr Name="CompileOrder" Val="102"/>
                </FileInfo>
            </File>
            <File Path="$Prefix/uisrc/01_rtl/jpeg/yuv32_to_quad.v">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&R" Val="true"/>
                    <Attr Name="BelongTo" Val="design_1"/>
                    <Attr Name="CompileOrder" Val="103"/>
                </FileInfo>
            </File>
"@

    if (-not $txt.Contains($anchor)) {
        Write-Host "找不到锚点: $Path"
        return
    }
    $txt = $txt.Replace($anchor, $add)
    [IO.File]::WriteAllText($Path, $txt, (New-Object Text.UTF8Encoding($false)))
    Write-Host "已加入: $Path"
}

Add-Entry "$root\fpga\fpga_prj_Runs\syn_1\fpga_prj.prj" '../..'
Add-Entry "$root\fpga\fpga_prj.al" ''

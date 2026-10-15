<#
.SYNOPSIS
    在安路 uisrc 虚拟机 (uisrc@192.168.65.128) 上执行本地的 bash 脚本。

.DESCRIPTION
    为什么需要这个包装:
      1) PowerShell 传给 ssh.exe 的参数会被 Windows 重新分词, find 的 \( \) 与引号会被吃掉;
      2) PowerShell 5.1 默认按 ANSI 处理含中文的参数, 容易出乱码。
    做法: 把本地 .sh 脚本正文按 UTF-8 读入 -> 去 CRLF -> base64 -> 远端 base64 -d 落盘再 bash 执行。
    这样脚本里可以有括号、引号、中文、反斜杠, 都不受影响。

.PARAMETER File
    本地 bash 脚本路径 (相对当前目录或绝对路径)。

.PARAMETER ScriptArgs
    传给脚本的位置参数 (会原样拼到脚本名后面, 空格分隔; 含空格请自行加引号)。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\vmsh.ps1 -File tools\probe_env.sh
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$File,
    [string]$VmHost = '192.168.65.128',
    [string]$VmUser = 'uisrc',
    [string]$VmKey = "$env:USERPROFILE\.ssh\key\afc03_ed25519",
    [string[]]$ScriptArgs = @()
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $File)) { throw "脚本不存在: $File" }
$full = (Resolve-Path -LiteralPath $File).Path

$text = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
$text = $text -replace "`r`n", "`n" -replace "`r", "`n"      # bash 不认 CRLF
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))

$argStr = if ($ScriptArgs.Count -gt 0) { ' ' + ($ScriptArgs -join ' ') } else { '' }
$remote = "echo $b64 | base64 -d > /tmp/.vmsh_run.sh && bash /tmp/.vmsh_run.sh$argStr"

& ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $VmKey "$VmUser@$VmHost" $remote
exit $LASTEXITCODE

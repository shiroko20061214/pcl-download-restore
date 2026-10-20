#requires -Version 5.1
<#
.SYNOPSIS
    把 Restore-PCLDownload.ps1 打包成单文件 .bat
.DESCRIPTION
    生成的 .bat 自带 PowerShell 负载，双击即可运行，无需额外的 .ps1。
    负载以 UTF-8(带 BOM) 释放到临时目录后执行，退出即删除。
.EXAMPLE
    .\build.ps1
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Source) { $Source = Join-Path $PSScriptRoot 'Restore-PCLDownload.ps1' }
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'dist' }

if (-not (Test-Path -LiteralPath $Source)) { throw "找不到源脚本：$Source" }

$ps1 = [System.IO.File]::ReadAllText($Source, [System.Text.Encoding]::UTF8)
$ps1 = $ps1.TrimStart([char]0xFEFF)   # 去掉 BOM，避免混进负载
$ps1 = $ps1.Trim()

# 标记不能以完整字面量出现在提取命令里，否则 IndexOf 会先命中命令自身。
# 因此在生成物中把它拆成两段，运行时再拼回来。
$marker = '#::P' + 'S1::'

$header = @'
@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1
title PCL Download Restore

set "SELF=%~f0"
set "PAYLOAD=%TEMP%\pcl_restore_%RANDOM%%RANDOM%.ps1"

if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
    echo [ERROR] Windows PowerShell not found.
    pause
    exit /b 2
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::UTF8); $m='#::P'+'S1::'; $i=$t.IndexOf($m); if($i -lt 0){exit 2}; $b=$t.Substring($i+$m.Length).Trim(); [IO.File]::WriteAllText($env:PAYLOAD,$b,(New-Object Text.UTF8Encoding($true)))"
if errorlevel 1 goto :extract_failed

powershell -NoProfile -ExecutionPolicy Bypass -File "%PAYLOAD%" %*
set "RC=%ERRORLEVEL%"

del /f /q "%PAYLOAD%" >nul 2>&1
rem pause only when launched with no arguments (double-click); stay silent for scripting
if "%~1"=="" (
    echo.
    pause
)
exit /b %RC%

:extract_failed
echo [ERROR] Failed to unpack the PowerShell payload.
if "%~1"=="" pause
exit /b 2

'@

$out = $header + $marker + "`r`n" + $ps1 + "`r`n"

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$target = Join-Path $OutDir 'PCL-Download-Restore.bat'

# .bat 用 UTF-8 无 BOM 写出（cmd 对行首 BOM 敏感）
[System.IO.File]::WriteAllText($target, $out, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "已生成：$target" -ForegroundColor Green
Write-Host ("  大小：{0:N1} KB" -f ((Get-Item -LiteralPath $target).Length / 1KB))
Write-Host ("  校验：{0}" -f (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash)

# 自检：把负载抽出来做一次语法解析
$text = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)
$i = $text.IndexOf($marker)
if ($i -lt 0) { throw '自检失败：标记丢失' }
$body = $text.Substring($i + $marker.Length).Trim()

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('pcl-selfcheck-' + [guid]::NewGuid().ToString('N') + '.ps1')
[System.IO.File]::WriteAllText($tmp, $body, (New-Object System.Text.UTF8Encoding($true)))
try {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Host ("  L{0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor Red }
        throw "自检失败：负载有 $($errors.Count) 处语法错误"
    }
    Write-Host '  自检：负载语法正确' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

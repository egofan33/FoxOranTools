#Requires -Version 5.1
# 兼容 Windows PowerShell 5.1 与 PowerShell 7.x

# 彩色菜单脚本，由 build.bat 调用。

$ProgressPreference = "SilentlyContinue"

$modulePath = Join-Path $PSScriptRoot 'BuildHelper.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host "[ERROR] 找不到模块：$modulePath" -ForegroundColor Red
    exit 1
}
Import-Module $modulePath -Force -DisableNameChecking

# 首次运行自检：全局工具目录（默认 C:\APKTools）不存在或无写权限时，
# 自动触发 UAC 提权创建并授权当前用户；授权取消或失败时提示原因并退出。
try {
    Assert-GlobalToolsRoot
}
catch {
    Write-Host ''
    Write-Host '[ERROR] 初始化全局工具目录失败' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    Write-Host ''
    Read-Host ' 按 Enter 键退出'
    exit 1
}

function Get-EnvironmentStatus {
    <#
    .SYNOPSIS
        返回当前环境状态（JDK、Node、Android SDK）。
        优先检测全局工具目录 C:\APKTools，再检测系统 PATH。
    #>
    $status = @{
        JDK        = '未安装'
        Node       = '未安装'
        AndroidSdk = '未安装'
        Flutter    = '未安装'
        Cordova    = '未安装'
    }

    # JDK：优先 全局工具目录\jdk\{version}
    $toolsRoot = Get-GlobalToolsRoot
    $requiredJdk = Get-RequiredJdkMajorVersion
    $localJdkExe = Join-Path $toolsRoot "jdk\$requiredJdk\bin\java.exe"
    $javaExe = if (Test-Path -LiteralPath $localJdkExe) { $localJdkExe } else {
        $check = Check-Path -Name 'java'; if ($check.Exists) { $check.Path } else { $null }
    }
    if ($javaExe) {
        $major = Get-JavaMajorVersion -JavaExe $javaExe
        if ($major -eq $requiredJdk) {
            $status.JDK = "OK ($major)"
        }
        else {
            $status.JDK = "版本 $major（需要 $requiredJdk）"
        }
    }

    # Node.js：优先 全局工具目录\node\{version}
    $nodeRoot = Join-Path $toolsRoot 'node'
    $nodeExe = $null
    if (Test-Path -LiteralPath $nodeRoot) {
        $nodeExe = Get-ChildItem -LiteralPath $nodeRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'node.exe') } |
            Select-Object -First 1 |
            ForEach-Object { Join-Path $_.FullName 'node.exe' }
    }
    if (-not $nodeExe) {
        $check = Check-Path -Name 'node'; if ($check.Exists) { $nodeExe = $check.Path }
    }
    if ($nodeExe) {
        try {
            $version = (& $nodeExe --version 2>&1 | Select-Object -First 1) -replace '^v', ''
            $status.Node = "OK ($version)"
        }
        catch {
            $status.Node = 'OK'
        }
    }

    # Android SDK：优先 全局工具目录\android-sdk
    $localSdkRoot = Join-Path $toolsRoot 'android-sdk'
    $adbPath = if ((Test-Path -LiteralPath (Join-Path $localSdkRoot 'platform-tools\adb.exe')) -and
                  (Test-Path -LiteralPath (Join-Path $localSdkRoot 'build-tools'))) {
        Join-Path $localSdkRoot 'platform-tools\adb.exe'
    }
    else {
        $check = Check-Path -Name 'adb'; if ($check.Exists) { $check.Path } else { $null }
    }
    if ($adbPath) {
        $status.AndroidSdk = 'OK'
    }

    # Flutter SDK：优先 全局工具目录\flutter\{version}
    $flutterRootDir = Join-Path $toolsRoot 'flutter'
    $flutterFound = $false
    if (Test-Path -LiteralPath $flutterRootDir) {
        $flutterFound = [bool](Get-ChildItem -LiteralPath $flutterRootDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\flutter.bat') } |
            Select-Object -First 1)
    }
    if (-not $flutterFound) {
        $check = Check-Path -Name 'flutter'; if ($check.Exists) { $flutterFound = $true }
    }
    if ($flutterFound) {
        $status.Flutter = 'OK'
    }

    # Cordova CLI：检查 cordova 命令是否可用
    $cordovaCheck = Check-Path -Name 'cordova'
    if ($cordovaCheck.Exists) {
        try {
            $cordovaVer = (& $cordovaCheck.Path --version 2>&1 | Select-Object -First 1)
            $status.Cordova = "OK ($cordovaVer)"
        }
        catch {
            $status.Cordova = 'OK'
        }
    }

    return $status
}

function Clear-MenuScreen {
    # 使用 .NET Console 清屏，避免 CMD 与 PowerShell 编码不一致导致的重影
    try {
        [System.Console]::Clear()
    }
    catch {
        Clear-Host
    }
}

function Show-Menu {
    Clear-MenuScreen
    $envStatus = Get-EnvironmentStatus

    Write-Host ''
    Write-Host '====================================================' -ForegroundColor Cyan
    Write-Host '     APK 一键构建工具箱 (Windows Hybrid Build)|作者:EGOFAN' -ForegroundColor Magenta
    Write-Host '====================================================' -ForegroundColor Cyan
    Write-Host '  自动下载 JDK / Android SDK / Node.js 便携版' -ForegroundColor Blue
    Write-Host '  所有依赖仅注入当前会话 PATH，不修改系统变量' -ForegroundColor Blue
    Write-Host '  感谢Odriver为本项目做宣传' -ForegroundColor DarkGreen
    Write-Host '====================================================' -ForegroundColor Cyan
    Write-Host "  [环境状态]  JDK: $($envStatus.JDK)  |  Node: $($envStatus.Node)  |  Android SDK: $($envStatus.AndroidSdk)  |  Flutter: $($envStatus.Flutter)  |  Cordova: $($envStatus.Cordova)" -ForegroundColor Yellow
    Write-Host ''
    Write-Host ' [1] 全自动构建' -ForegroundColor Green
    Write-Host '     - 下载依赖 + Expo prebuild + 签名输出 APK(新项目第一次构建耗时较长)' -ForegroundColor Gray
    Write-Host ' [2] 清理缓存' -ForegroundColor Yellow
    Write-Host '     - 停止 Gradle Daemon 并清理构建缓存' -ForegroundColor Gray
    Write-Host ' [3] 配置环境' -ForegroundColor Cyan
    Write-Host '     - 仅安装/检查 JDK、Node.js、Android SDK（Flutter 项目含 Flutter SDK 与便携 git）' -ForegroundColor Gray
    Write-Host ' [0] 退出' -ForegroundColor Red
    Write-Host ''
}

do {
    Show-Menu
    $choice = Read-Host ' 请输入选项 [0-3]'

    $buildCore = Join-Path $PSScriptRoot 'BuildCore.ps1'

    switch ($choice) {
        '1' {
            Write-Host ''
            # 代理分流：有梯子的用户选 N 直连，国内用户默认 Y 走 gh-proxy.com 加速
            $proxyChoice = Read-Host ' 是否启用下载代理加速？（国内用户建议Y，有梯子的用户选N） [Y/n]'
            Remove-Item Env:\BUILDHELPER_NO_PROXY -ErrorAction SilentlyContinue
            if ($proxyChoice -eq 'n' -or $proxyChoice -eq 'N') {
                $env:BUILDHELPER_NO_PROXY = '1'
                Write-Host '[INFO] 已选择直连下载（不使用代理）' -ForegroundColor DarkGray
            } else {
                Write-Host '[INFO] 已选择代理加速下载' -ForegroundColor DarkGray
            }
            Write-Host '[INFO] 开始：全自动构建' -ForegroundColor Green
            # 以子进程运行 BuildCore.ps1：其内部的 exit 只结束子进程，不会终止菜单；
            # 退出码经 $LASTEXITCODE 正确回传
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -OutputFormat Text -File $buildCore -Action Build
            Remove-Item Env:\BUILDHELPER_NO_PROXY -ErrorAction SilentlyContinue
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) { Write-Host "[ERROR] 构建失败（退出码 $exitCode）" -ForegroundColor Red }
            Write-Host ''
            Read-Host ' 按 Enter 键返回菜单'
        }
        '2' {
            Write-Host ''
            Write-Host '[INFO] 开始：清理缓存' -ForegroundColor Yellow
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -OutputFormat Text -File $buildCore -Action Clean
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) { Write-Host "[ERROR] 清理失败（退出码 $exitCode）" -ForegroundColor Red }
            Write-Host ''
            Read-Host ' 按 Enter 键返回菜单'
        }
        '3' {
            Write-Host ''
            # 代理分流：有梯子的用户选 N 直连，国内用户默认 Y 走 gh-proxy.com 加速
            $proxyChoice = Read-Host ' 是否启用下载代理加速？（国内用户建议Y，有梯子的用户选N） [Y/n]'
            Remove-Item Env:\BUILDHELPER_NO_PROXY -ErrorAction SilentlyContinue
            if ($proxyChoice -eq 'n' -or $proxyChoice -eq 'N') {
                $env:BUILDHELPER_NO_PROXY = '1'
                Write-Host '[INFO] 已选择直连下载（不使用代理）' -ForegroundColor DarkGray
            } else {
                Write-Host '[INFO] 已选择代理加速下载' -ForegroundColor DarkGray
            }
            Write-Host '[INFO] 开始：配置环境' -ForegroundColor Cyan
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -OutputFormat Text -File $buildCore -Action SetupEnv
            Remove-Item Env:\BUILDHELPER_NO_PROXY -ErrorAction SilentlyContinue
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) { Write-Host "[ERROR] 环境配置失败（退出码 $exitCode）" -ForegroundColor Red }
            Write-Host ''
            Read-Host ' 按 Enter 键返回菜单'
        }
        '0' { exit 0 }
        default {
            Write-Host '[ERROR] 无效选项' -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
} while ($true)

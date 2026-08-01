#Requires -Version 5.1
#=============================================================================
# 03-ToolsRoot.ps1 - 全局工具目录与权限自愈
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================

function Test-GlobalToolsRootWritable {
    <#
        检测是否有权限在 C:\APKTools 创建目录/文件。
    #>
    try {
        $testDir = Join-Path $script:GlobalToolsRoot ".write-test"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $testFile = Join-Path $testDir "tmp"
        [System.IO.File]::WriteAllText($testFile, "test")
        Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

function Test-IsAdmin {
    <#
        判断当前进程是否拥有管理员权限。
    #>
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Request-GlobalToolsRootAccess {
    <#
    .SYNOPSIS
        通过 UAC 提权创建全局工具目录并授予当前用户修改权限。
    .DESCRIPTION
        普通方式创建失败（权限不足）或目录已存在但当前用户无写权限时调用。
        已是管理员则直接修复；否则弹出 UAC 授权框，由提权子进程完成：
          1. 创建目录（若不存在）；
          2. icacls 授予当前用户 (OI)(CI)M —— 管理员创建的目录继承 C:\ 根 ACL，
             普通用户默认只读，不授权则后续安装仍会失败。
        用户取消授权或提权失败时抛出友好中文错误；成功返回后由调用方复验。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    $userName = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    # 已是管理员：无需 UAC，直接创建/修复 ACL
    if (Test-IsAdmin) {
        Write-BuildInfo "当前已是管理员权限，直接修复目录权限：$Root"
        if (-not (Test-Path -LiteralPath $Root)) {
            New-Item -ItemType Directory -Path $Root -Force | Out-Null
        }
        & icacls.exe $Root /grant "${userName}:(OI)(CI)M" /T | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "icacls 授权失败（退出码 $LASTEXITCODE）：$Root"
        }
        return
    }

    Write-BuildInfo "首次使用需要创建/修复全局工具目录：$Root"
    Write-BuildInfo "即将弹出 UAC 授权框，请点击「是」完成一次性授权（授权后普通权限即可使用）。"

    # 提权子进程与当前会话共享的临时错误日志（同一用户的 TEMP 一致）
    $logPath = Join-Path ([System.IO.Path]::GetTempPath()) 'APKTools-elevate-error.log'
    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue

    $escapedRoot = $Root.Replace("'", "''")
    $escapedUser = $userName.Replace("'", "''")
    $escapedLog  = $logPath.Replace("'", "''")

    $elevatedScript = @"
`$ErrorActionPreference = 'Stop'
try {
    if (-not (Test-Path -LiteralPath '$escapedRoot')) {
        New-Item -ItemType Directory -Path '$escapedRoot' -Force | Out-Null
    }
    & icacls.exe '$escapedRoot' /grant '${escapedUser}:(OI)(CI)M' /T | Out-Null
    if (`$LASTEXITCODE -ne 0) { throw "icacls exit code `$LASTEXITCODE" }
    exit 0
}
catch {
    try { `$_.Exception.Message | Out-File -FilePath '$escapedLog' -Encoding utf8 } catch { }
    exit 1
}
"@

    # Base64(UTF-16LE) 编码命令，规避命令行引号转义问题
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($elevatedScript))

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
    }
    catch {
        # Win32Exception 1223：用户在 UAC 弹窗中点了「否」
        throw @"
需要管理员授权才能完成首次初始化：$Root

未获得授权（UAC 弹窗被取消）。请重新运行并在 UAC 弹窗中点击「是」。
也可以：
  1. 右键 PowerShell / CMD，选择「以管理员身份运行」后重试一次；
  2. 或在 config.json 的 paths.globalToolsRoot 改用无需提权的路径（如 D:\APKTools）。

详情：$($_.Exception.Message)
"@
    }

    if ($proc.ExitCode -ne 0) {
        $detail = ''
        if (Test-Path -LiteralPath $logPath) {
            $detail = (Get-Content -LiteralPath $logPath -Raw -Encoding UTF8).Trim()
            Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
        }
        throw @"
提权初始化全局工具目录失败：$Root
$detail

请右键 PowerShell / CMD，选择「以管理员身份运行」后重试一次；
或在 config.json 的 paths.globalToolsRoot 改用无需提权的路径（如 D:\APKTools）。
"@
    }

    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
}

function Assert-GlobalToolsRoot {
    <#
        确保全局工具根目录存在且当前用户可写。三级自愈：
          1. 已存在且可写 → 直接返回（每次启动的毫秒级快路径）；
          2. 不存在 → 先尝试普通创建（自定义到非系统盘等无权限限制路径时无需提权）；
          3. 创建失败，或目录已存在但不可写（含旧版本管理员创建未赋权的遗留情况）
             → UAC 提权创建并 icacls 授予当前用户修改权限，完成后复验。
    #>
    $root = $script:GlobalToolsRoot

    # 快路径：存在且可写
    if ((Test-Path -LiteralPath $root) -and (Test-GlobalToolsRootWritable)) {
        return
    }

    # 直建路径：不存在则先尝试普通创建
    if (-not (Test-Path -LiteralPath $root)) {
        Write-BuildInfo "首次使用，准备创建全局工具目录：$root"
        try {
            New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-BuildInfo "当前权限无法直接创建，尝试 UAC 提权……"
        }
        if ((Test-Path -LiteralPath $root) -and (Test-GlobalToolsRootWritable)) {
            return
        }
    }

    # 提权路径：创建失败或目录存在但不可写
    Request-GlobalToolsRootAccess -Root $root

    if (-not (Test-GlobalToolsRootWritable)) {
        throw @"
全局工具目录已创建，但当前用户仍没有写入权限：$root

请右键 PowerShell / CMD，选择「以管理员身份运行」后重新执行一次本脚本。
首次创建完成后，后续普通权限即可使用。
"@
    }
}

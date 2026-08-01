#Requires -Version 5.1
# 兼容 Windows PowerShell 5.1 与 PowerShell 7.x

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Build", "Clean", "SetupEnv")]
    [string]$Action
)

# 设为 Continue，避免外部命令（java/gradle/npx）的 stderr 被当作致命错误。
# 关键位置仍通过 -ErrorAction Stop 与 $LASTEXITCODE 显式控制。
$ErrorActionPreference = "Continue"

# 隐藏 PowerShell 进度条，防止下载/解压进度条残留在 CMD 菜单中。
$ProgressPreference = "SilentlyContinue"

$modulePath = Join-Path $PSScriptRoot "BuildHelper.psm1"
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host "[ERROR] 找不到模块：$modulePath" -ForegroundColor Red
    exit 1
}

Import-Module $modulePath -Force -DisableNameChecking

# 确定项目类型：仅 Build 动作询问；Clean/SetupEnv 保持自动检测，不增加交互摩擦
$projectType = 'Auto'
if ($Action -eq 'Build') {
    $projectType = Select-ProjectType
}

# 确定项目根目录：当前目录若包含项目特征则直接使用，否则按所选类型校验并弹窗选择
$projectRoot = Get-ProjectRootDirectory -ScriptRoot $PSScriptRoot -ProjectType $projectType

# 初始化项目路径配置
Initialize-BuildConfiguration -ProjectRoot $projectRoot -ProjectType $projectType

switch ($Action) {
    "Build" {
        Start-ReleaseBuild
    }
    "Clean" {
        Clear-BuildCaches
    }
    "SetupEnv" {
        Initialize-BuildEnvironment
    }
    default {
        Write-Host "[ERROR] 未知操作：$Action" -ForegroundColor Red
        exit 1
    }
}

exit 0

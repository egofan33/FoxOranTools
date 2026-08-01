#Requires -Version 5.1
# 兼容 Windows PowerShell 5.1 与 PowerShell 7.x

# =============================================================================
# BuildHelper 模块加载器
# 全部功能实现按功能域拆分至 Modules\*.ps1，本文件按固定顺序点源装配。
# 分文件与本模块共享同一 $script: 作用域（配置默认值、运行时状态）。
# =============================================================================

# 模块根目录（即项目根目录）：供分文件定位 config.json 与默认项目路径，
# 替代分文件内部的 $PSScriptRoot（点源时会指向 Modules\ 子目录）。
$script:BuildHelperRoot = $PSScriptRoot

$script:BuildHelperModules = @(
    '00-Config'         # 配置加载与模块默认值（必须最先加载）
    '01-Logging'        # 日志与进度输出
    '02-Paths'          # 路径检测与环境工具
    '03-ToolsRoot'      # 全局工具目录与权限自愈
    '04-Network'        # 下载、进度与解压
    '05-Resolvers'      # 依赖版本与下载地址解析
    '06-Installers'     # 便携依赖安装器
    '07-ProjectDetect'  # 项目类型检测与路径初始化
    '08-GitMirror'      # GitHub git 依赖镜像重写
    '09-NodeModules'    # node_modules 安装与链接修复
    '10-Gradle'         # Gradle 配置、缓存修复与构建
    '11-Flutter'        # Flutter 构建与 pub 依赖处理
    '12-Signing'        # 签名材料与 APK 输出
    '13-Build'          # 环境初始化、缓存清理与构建主流程
    '14-YamlLite'       # 缩进感知的 YAML 子集解析器（pubspec.yaml / pubspec.lock）
    '15-Cordova'        # Cordova 项目构建（CLI 安装、平台管理、APK 构建）
    '16-Requirements'   # 跨项目 SDK 需求解析、JDK 自适应、SDK 补装与构建失败诊断
)

foreach ($modulePart in $script:BuildHelperModules) {
    $modulePartPath = Join-Path $script:BuildHelperRoot "Modules\$modulePart.ps1"
    if (-not (Test-Path -LiteralPath $modulePartPath)) {
        throw "找不到模块分文件：$modulePartPath"
    }
    . $modulePartPath
}

Export-ModuleMember -Function *

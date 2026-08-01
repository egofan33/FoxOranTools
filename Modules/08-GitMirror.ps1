#Requires -Version 5.1
#=============================================================================
# 08-GitMirror.ps1 - GitHub git 依赖镜像重写
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================

function Get-PubspecGitDependencyUrls {
    <#
        收集项目所有 GitHub git 依赖 URL（去重）。
        优先解析 pubspec.lock（含 transitive git 依赖）；不存在时回退 pubspec.yaml。
    #>
    $content = $null
    $lockPath = Join-Path $script:MobileRoot 'pubspec.lock'
    if (Test-Path -LiteralPath $lockPath) {
        $content = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    if ([string]::IsNullOrEmpty($content)) {
        $pubspecPath = Join-Path $script:MobileRoot 'pubspec.yaml'
        if (Test-Path -LiteralPath $pubspecPath) {
            $content = Get-Content -LiteralPath $pubspecPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    }
    if ([string]::IsNullOrEmpty($content)) { return @() }

    $doc = ConvertFrom-YamlLite -Content $content
    $urls = @(Find-YamlLiteValues -Node $doc -Key 'url') |
        Where-Object { $_ -match '^https://github\.com/' }
    return @($urls | Select-Object -Unique)
}

function Test-GitMirrorReachable {
    <#
        ls-remote 探测指定 URL 的 git 协议可用性。
        低水位超时（连接建立后无数据传输即中止），避免探测本身卡死。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProbeUrl,
        [Parameter(Mandatory = $true)][string]$GitExe,
        [int]$LowSpeedTimeSec = 15
    )
    & $GitExe -c http.lowSpeedLimit=1 -c http.lowSpeedTime=$LowSpeedTimeSec ls-remote $ProbeUrl HEAD 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Set-GitCloneMirror {
    <#
        会话级注入 git url.insteadOf 重写（GIT_CONFIG_* 环境变量，不修改 .gitconfig；
        flutter 子进程继承环境变量，对 pub 的 git clone 透明生效）：
        1. 全局默认通道：显式 git.mirrorInsteadOf 优先，否则按 mirrorCandidates 探测选定；
        2. 逐仓库修正：解析项目 pubspec.lock/pubspec.yaml 的 GitHub git 依赖，
           经全局通道逐一 ls-remote 探测；失败的仓库依次尝试其余候选与直连，
           并注入该仓库的精确 insteadOf 规则（git 多条规则取最长前缀匹配）——
           镜像对个别小众仓库可能 502/未收录，全局可用不代表逐仓库可用；
        3. 注入低水位超时（停滞 60 秒中止），防止镜像挂起导致 pub get 无限等待。
    #>
    $gitExe = (Check-Path -Name 'git').Path
    if (-not $gitExe) {
        $portableGitHome = Find-PortableGitHome
        if ($portableGitHome) { $gitExe = Join-Path $portableGitHome 'cmd\git.exe' }
    }

    # 通道定义：Prefix 为 github.com 前缀的替换目标；$null 表示直连
    $channels = [System.Collections.Generic.List[object]]::new()
    foreach ($prefix in $script:GitMirrorCandidates) {
        if (-not [string]::IsNullOrWhiteSpace($prefix)) {
            $channels.Add([pscustomobject]@{ Prefix = $prefix })
        }
    }
    $directChannel = [pscustomobject]@{ Prefix = $null }

    # 1. 选定全局通道
    $globalChannel = $null
    if (-not [string]::IsNullOrWhiteSpace($script:GitMirrorInsteadOf)) {
        $globalChannel = [pscustomobject]@{ Prefix = $script:GitMirrorInsteadOf }
    }
    elseif ($gitExe -and $channels.Count -gt 0) {
        Write-BuildInfo '正在探测 GitHub git 镜像可用性（ls-remote 小仓库）...'
        foreach ($channel in $channels) {
            if (Test-GitMirrorReachable -ProbeUrl ($channel.Prefix + 'octocat/Hello-World.git') -GitExe $gitExe) {
                $globalChannel = $channel
                break
            }
            Write-BuildWarn "git 镜像不可用：$($channel.Prefix)"
        }
    }
    if ($null -eq $globalChannel) { $globalChannel = $directChannel }

    # 2. 逐仓库修正
    $perUrlRules = [System.Collections.Generic.List[object]]::new()
    $repoUrls = @(Get-PubspecGitDependencyUrls)
    if ($repoUrls.Count -gt 0 -and $gitExe) {
        Write-BuildInfo "检测到 $($repoUrls.Count) 个 GitHub git 依赖，正在逐仓库验证通道可用性..."
        $i = 0
        foreach ($repoUrl in $repoUrls) {
            $i++
            $repoPath = $repoUrl -replace '^https://github\.com/', ''
            $probeOrder = @($globalChannel) + @($channels | Where-Object { $_.Prefix -ne $globalChannel.Prefix }) + @($directChannel)
            $chosen = $null
            foreach ($channel in $probeOrder) {
                $probeUrl = if ($channel.Prefix) { $channel.Prefix + $repoPath } else { $repoUrl }
                if (Test-GitMirrorReachable -ProbeUrl $probeUrl -GitExe $gitExe -LowSpeedTimeSec 10) {
                    $chosen = $channel
                    break
                }
            }
            if ($null -eq $chosen) {
                Write-BuildWarn "[$i/$($repoUrls.Count)] 所有通道均不可用：$repoUrl（将按全局通道尝试，可能失败）"
            }
            elseif ($chosen.Prefix -ne $globalChannel.Prefix) {
                $label = if ($chosen.Prefix) { $chosen.Prefix } else { '直连 github.com' }
                Write-BuildWarn "[$i/$($repoUrls.Count)] 全局通道不可用，改用 ${label}：$repoUrl"
                $perUrlRules.Add([pscustomobject]@{ Original = $repoUrl; Channel = $chosen })
            }
            else {
                Write-BuildInfo "[$i/$($repoUrls.Count)] OK：$repoUrl"
            }
        }
    }

    # 3. 注入 GIT_CONFIG_*（进程级，子进程退出即失效）
    $entries = [System.Collections.Generic.List[object]]::new()
    if ($globalChannel.Prefix) {
        $entries.Add([pscustomobject]@{ Key = "url.$($globalChannel.Prefix).insteadOf"; Value = 'https://github.com/' })
    }
    foreach ($rule in $perUrlRules) {
        if ($rule.Channel.Prefix) {
            # 精确重写：原 URL → 镜像 URL（最长前缀匹配优先于全局规则）
            $rewriteTo = $rule.Original -replace '^https://github\.com/', $rule.Channel.Prefix
        }
        else {
            # 自映射：豁免全局重写，强制该仓库直连
            $rewriteTo = $rule.Original
        }
        $entries.Add([pscustomobject]@{ Key = "url.$rewriteTo.insteadOf"; Value = $rule.Original })
    }
    $entries.Add([pscustomobject]@{ Key = 'http.lowSpeedLimit'; Value = '1024' })
    $entries.Add([pscustomobject]@{ Key = 'http.lowSpeedTime'; Value = '60' })
    # Windows MAX_PATH(260)：未开 longpaths 时 checkout 静默跳过超长文件（如
    # flutter_inappwebview 插件中 >260 字符的 .java 丢失，编译报"找不到符号"），
    # 会话级开启，pub 克隆子进程继承生效，不改用户 .gitconfig
    $entries.Add([pscustomobject]@{ Key = 'core.longpaths'; Value = 'true' })

    $env:GIT_CONFIG_COUNT = [string]$entries.Count
    for ($n = 0; $n -lt $entries.Count; $n++) {
        [System.Environment]::SetEnvironmentVariable("GIT_CONFIG_KEY_$n", $entries[$n].Key, 'Process')
        [System.Environment]::SetEnvironmentVariable("GIT_CONFIG_VALUE_$n", $entries[$n].Value, 'Process')
    }

    $globalLabel = if ($globalChannel.Prefix) { $globalChannel.Prefix } else { '直连 github.com' }
    Write-BuildInfo "GitHub git 通道已注入：全局=$globalLabel，逐仓库修正 $($perUrlRules.Count) 条，低水位保护 60s，长路径支持（core.longpaths）。"
}

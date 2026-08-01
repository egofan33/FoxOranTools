#Requires -Version 5.1
#=============================================================================
# 14-YamlLite.ps1 - 缩进感知的 YAML 子集解析器（状态机 + 层级栈）
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================
#
# 设计目标：替换 Flutter 工具链中对 pubspec.yaml / pubspec.lock 的脆弱正则抠段，
# 改为按行处理的缩进感知状态机，对注释、任意缩进深度、引号标量、列表项均安全。
#
# 支持的 YAML 子集：
#   - 块式映射（map）：key: 或 key: value
#   - 任意缩进深度与任意缩进单位（空格/Tab 各计 1 字符）
#   - 整行注释（# 起始）与行尾注释（# 前为空白且不在引号内）
#   - 单/双引号包裹的标量（仅去首尾引号，不做嵌套转义）
#   - 列表项（- item）与非键值行（多行标量延续等）安全跳过，不崩溃
#
# 已知限制（与旧正则语义持平，文档透明）：
#   - 不支持内联 flow map（environment: {sdk: ">=3.0.0"}）
#   - 不支持 YAML 引号内的转义（'' / \"）
#   - Tab 按 1 个字符计缩进（与既有代码 .Length 口径一致）

function ConvertFrom-YamlLite {
    <#
        将 YAML 子集文本解析为嵌套 [ordered] 字典。
        空内容 / 纯注释返回空字典，不抛异常。
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    # 层级栈：每帧 @{ Indent = <int>; Map = [ordered]@{} }；根帧 Indent = -1
    $stack = [System.Collections.Generic.List[object]]::new()
    $stack.Add([pscustomobject]@{ Indent = -1; Map = [ordered]@{} })

    if ([string]::IsNullOrEmpty($Content)) { return $stack[0].Map }

    foreach ($rawLine in ($Content -split "`r`n|`r|`n")) {
        # 空行 / 整行注释：跳过
        if ($rawLine -match '^\s*($|#)') { continue }

        # 计算前导空白字符数（空格/Tab 各计 1）
        $leading = ($rawLine -replace '^(\s*).*', '$1').Length
        $indent = $leading

        # 行尾注释剥离：逐字符扫描，跟踪单/双引号状态；
        # # 不在引号内且其前一字符为空白（或位于行首）才视为注释起点。
        $line = $rawLine
        $inSingle = $false
        $inDouble = $false
        $commentAt = -1
        for ($i = 0; $i -lt $rawLine.Length; $i++) {
            $c = $rawLine[$i]
            if ($inSingle) {
                if ($c -eq '''') { $inSingle = $false }
            }
            elseif ($inDouble) {
                if ($c -eq '"') { $inDouble = $false }
            }
            elseif ($c -eq '''') {
                $inSingle = $true
            }
            elseif ($c -eq '"') {
                $inDouble = $true
            }
            elseif ($c -eq '#') {
                $prevIsSpace = ($i -eq 0) -or [char]::IsWhiteSpace($rawLine[$i - 1])
                if ($prevIsSpace) { $commentAt = $i; break }
            }
        }
        if ($commentAt -ge 0) {
            $line = $rawLine.Substring(0, $commentAt)
        }

        # 列表项：安全跳过（列表值本解析器不建模）
        if ($line -match '^\s*-\s') { continue }
        # 非键值行（如多行标量延续）：安全跳过
        if ($line -notmatch '^\s*([A-Za-z0-9_.\-]+)\s*:\s*(.*)$') { continue }

        $key = $Matches[1]
        $value = $Matches[2]

        # 回弹出栈：缩进 <= 当前栈顶缩进的帧全部弹出，栈顶即父 map
        while ($stack.Count -gt 1 -and $stack[$stack.Count - 1].Indent -ge $indent) {
            $stack.RemoveAt($stack.Count - 1)
        }
        $parent = $stack[$stack.Count - 1].Map

        if ([string]::IsNullOrEmpty($value.Trim())) {
            # key: 视为子 map；无子项时为空 map（无害）
            $childMap = [ordered]@{}
            $parent[$key] = $childMap
            $stack.Add([pscustomobject]@{ Indent = $indent; Map = $childMap })
        }
        else {
            # 标量：去首尾单/双引号
            $scalar = $value.Trim()
            if (($scalar.Length -ge 2) -and ($scalar[0] -eq '''' -and $scalar[-1] -eq '''')) {
                $scalar = $scalar.Substring(1, $scalar.Length - 2)
            }
            elseif (($scalar.Length -ge 2) -and ($scalar[0] -eq '"' -and $scalar[-1] -eq '"')) {
                $scalar = $scalar.Substring(1, $scalar.Length - 2)
            }
            $parent[$key] = $scalar
        }
    }

    return $stack[0].Map
}

function Get-YamlLiteSectionRaw {
    <#
        行级定位顶层指定键，返回其段体原文（供 dependency_overrides 逐字重发）。
        段体 = 顶层键之后所有"缩进更深"或"为注释/空行"的行，直到列 0 的真实键为止。
        列 0 注释归属段体（比旧正则 ^\S 截断更高保真，重发到 overrides 文件无害）。
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if ([string]::IsNullOrEmpty($Content)) {
        return @{ Found = $false; Body = '' }
    }

    $lines = $Content -split "`r`n|`r|`n"
    $startIdx = -1
    $headerIndent = -1
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $l = $lines[$i]
        if ($l -match '^\s*#') { continue }
        $m = [regex]::Match($l, '^(\s*)([A-Za-z0-9_.\-]+)\s*:')
        if ($m.Success -and $m.Groups[2].Value -eq $Key) {
            $startIdx = $i
            $headerIndent = $m.Groups[1].Value.Length
            break
        }
    }
    if ($startIdx -lt 0) {
        return @{ Found = $false; Body = '' }
    }

    $bodyLines = [System.Collections.Generic.List[string]]::new()
    for ($i = $startIdx + 1; $i -lt $lines.Length; $i++) {
        $l = $lines[$i]
        # 列 0 真实键（缩进 0 且非注释）：段体结束
        if ($l -notmatch '^\s' -and $l -notmatch '^\s*#' -and $l.Trim().Length -gt 0) {
            break
        }
        # 注释 / 空行：归属段体（保真）
        if ($l -match '^\s*($|#)') {
            $bodyLines.Add($l)
            continue
        }
        # 缩进更深：归属段体
        $ind = ($l -replace '^(\s*).*', '$1').Length
        if ($ind -gt $headerIndent) {
            $bodyLines.Add($l)
        }
        else {
            break
        }
    }

    return @{ Found = $true; Body = ($bodyLines -join "`n").TrimEnd() }
}

function Find-YamlLiteValues {
    <#
        递归收集任意层级指定键的标量值（供 git url 全文扫描，兼容 lock 深层结构）。
        返回字符串数组（不去重，调用方去重）。
    #>
    param(
        [Parameter(Mandatory = $true)]$Node,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $result = @()
    if ($null -eq $Node) { return $result }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in $Node.Keys) {
            if ($k -eq $Key) {
                $v = $Node[$k]
                if ($null -ne $v -and -not ($v -is [System.Collections.IDictionary]) -and -not ($v -is [System.Collections.IList])) {
                    $result += [string]$v
                }
            }
            $child = $Node[$k]
            if ($child -is [System.Collections.IDictionary] -or $child -is [System.Collections.IList]) {
                $result += @(Find-YamlLiteValues -Node $child -Key $Key)
            }
        }
    }
    elseif ($Node -is [System.Collections.IList]) {
        foreach ($item in $Node) {
            if ($item -is [System.Collections.IDictionary] -or $item -is [System.Collections.IList]) {
                $result += @(Find-YamlLiteValues -Node $item -Key $Key)
            }
        }
    }
    return $result
}

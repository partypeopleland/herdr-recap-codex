param(
    [ValidateSet('inspect', 'start', 'write')][string]$Action,
    [string]$Value = ''
)

$ErrorActionPreference = 'Stop'
$language = 'zh-TW'
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$sessions = Join-Path $codexHome 'sessions'
$cacheDir = Join-Path $env:LOCALAPPDATA 'HerdrRecapCodex\recaps'
$uuidPattern = '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'

function Session-File([string]$id) {
    if ($id -notmatch "^$uuidPattern$") { throw 'Invalid session ID' }
    @(Get-ChildItem -LiteralPath $sessions -Filter "rollout-*-$id.jsonl" -Recurse -File -ErrorAction SilentlyContinue)
}

function Read-FirstLine([string]$path) {
    $stream = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $reader = [System.IO.StreamReader]::new($stream)
        return $reader.ReadLine()
    } finally { $stream.Dispose() }
}

function Resolve-Session([int]$rootPid) {
    $processes = @(Get-CimInstance Win32_Process)
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($rootPid)
    $descendants = @()
    while ($queue.Count) {
        $parent = $queue.Dequeue()
        foreach ($child in @($processes | Where-Object ParentProcessId -eq $parent)) {
            $descendants += $child
            $queue.Enqueue([int]$child.ProcessId)
        }
    }
    $codex = @($descendants | Where-Object {
        $_.Name -eq 'codex.exe' -and $_.CommandLine -notmatch '\b(?:app-server|exec-server)\b'
    })
    if ($codex.Count -ne 1) { throw "Expected one Codex process under terminal $rootPid; found $($codex.Count)" }
    $proc = $codex[0]
    $started = [datetime]$proc.CreationDate
    $cmd = [string]$proc.CommandLine
    $cwd = ''
    if ($cmd -match '(?:^|\s)-C\s+(?:"([^"]+)"|(\S+))') { $cwd = if ($Matches[1]) { $Matches[1] } else { $Matches[2] } }
    $resumed = ''
    if ($cmd -match "\bresume\s+($uuidPattern)\b") { $resumed = $Matches[1] }
    $files = if ($resumed) { @(Session-File $resumed) } else {
        @(Get-ChildItem -LiteralPath $sessions -Filter 'rollout-*.jsonl' -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object CreationTime -ge $started.AddMinutes(-1))
    }
    $candidates = @()
    foreach ($file in $files) {
        try {
            $line = Read-FirstLine $file.FullName
            $meta = $line | ConvertFrom-Json
            if ($meta.type -ne 'session_meta' -or $meta.payload.originator -ne 'codex-tui') { continue }
            $id = [string]$meta.payload.session_id
            if ($id -notmatch "^$uuidPattern$") { continue }
            if ($resumed -and $id -ne $resumed) { continue }
            if ($cwd -and [string]$meta.payload.cwd -ine $cwd) { continue }
            if (-not $resumed) {
                $delta = ([datetime]$meta.payload.timestamp - $started.ToUniversalTime()).TotalSeconds
                if ($delta -lt -2 -or $delta -gt 15) { continue }
            }
            $candidates += [pscustomobject]@{ id = $id; file = $file.FullName }
        } catch { continue }
    }
    if ($candidates.Count -ne 1) { throw "Cannot identify one Codex session for terminal $rootPid; found $($candidates.Count)" }
    return $candidates[0]
}

function Cache-Path([string]$id) { Join-Path $cacheDir "$id.json" }

function Cache-State($session) {
    $file = Get-Item -LiteralPath $session.file
    $cache = $null
    $path = Cache-Path $session.id
    if (Test-Path -LiteralPath $path) {
        try { $cache = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { $cache = $null }
    }
    $fresh = $null -ne $cache -and $cache.language -eq $language -and
        [long]$cache.size -eq $file.Length -and [long]$cache.mtime -eq $file.LastWriteTimeUtc.Ticks
    [pscustomobject]@{
        id = $session.id
        recap = if ($cache) { [string]$cache.recap } else { '' }
        fresh = [bool]$fresh
        at = if ($cache) { [string]$cache.at } else { '' }
    }
}

function Write-Recap([string]$id) {
    $mutex = [System.Threading.Mutex]::new($false, "Local\HerdrRecapCodex_$id")
    $locked = $false
    try {
        $locked = $mutex.WaitOne(0)
        if (-not $locked) { return }
        $files = @(Session-File $id)
        if ($files.Count -ne 1) { throw 'Session transcript is missing or ambiguous' }
        $session = [pscustomobject]@{ id = $id; file = $files[0].FullName }
        if ((Cache-State $session).fresh) { return }
        $file = Get-Item -LiteralPath $session.file
        $size, $mtime = $file.Length, $file.LastWriteTimeUtc.Ticks
        $temp = Join-Path $env:TEMP ("herdr-recap-codex-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temp | Out-Null
        try {
            $out = Join-Path $temp 'recap.txt'
            $prompt = 'Stop: this is a question about this session, not a continuation of its work. Do not run commands or use tools. 用繁體中文在 80 字內摘要：正在處理什麼、目前進度、下一步。只輸出摘要。'
            Get-ChildItem Env:HERDR_* -ErrorAction SilentlyContinue | Remove-Item
            $codexCommand = Get-Command codex.cmd,codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $codexCommand) { throw 'Codex CLI was not found on PATH' }
            Push-Location $temp
            try {
                & $codexCommand.Source exec fork $id --ephemeral --skip-git-repo-check -c 'sandbox_mode="read-only"' -o $out $prompt *> (Join-Path $temp 'codex.log')
                if ($LASTEXITCODE -ne 0) { throw "Codex exited with code $LASTEXITCODE" }
            } finally { Pop-Location }
            $recap = (Get-Content -LiteralPath $out -Raw -ErrorAction Stop).Trim()
            if (-not $recap) { throw 'Codex returned an empty recap' }
            if ($recap -match '<tool_call>|<\|tool_call|<function_calls>|<invoke') { throw 'Codex returned a tool call instead of a recap' }
            New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
            $data = @{ session = $id; language = $language; size = $size; mtime = $mtime; recap = $recap; at = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress
            $tmpCache = (Cache-Path $id) + '.tmp'
            [System.IO.File]::WriteAllText($tmpCache, $data, [System.Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $tmpCache -Destination (Cache-Path $id) -Force
            Remove-Item -LiteralPath (Join-Path $cacheDir "$id.error") -ErrorAction SilentlyContinue
        } finally {
            $resolved = [IO.Path]::GetFullPath($temp)
            $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
            if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
                [IO.Path]::GetFileName($resolved) -like 'herdr-recap-codex-*') {
                Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $cacheDir "$id.error"), $_.Exception.Message)
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

try {
    switch ($Action) {
        'inspect' {
            $result = @()
            foreach ($pidText in ($Value -split ',')) {
                if (-not $pidText) { continue }
                try {
                    $session = Resolve-Session ([int]$pidText)
                    $state = Cache-State $session
                    $errorPath = Join-Path $cacheDir "$($session.id).error"
                    $result += @{ pid = [int]$pidText; session = $state.id; recap = $state.recap; fresh = $state.fresh; at = $state.at; error = if (Test-Path -LiteralPath $errorPath) { Get-Content -LiteralPath $errorPath -Raw } else { '' } }
                } catch { $result += @{ pid = [int]$pidText; error = $_.Exception.Message } }
            }
            ConvertTo-Json -InputObject @($result) -Compress -Depth 4
        }
        'start' {
            $session = Resolve-Session ([int]$Value)
            if ((Cache-State $session).fresh) { '{"status":"cached"}'; break }
            $script = $PSCommandPath
            $arguments = '-NoProfile -File "{0}" write {1}' -f $script, $session.id
            Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList $arguments -WindowStyle Hidden
            '{"status":"started"}'
        }
        'write' { Write-Recap $Value }
    }
} catch {
    @{ error = $_.Exception.Message } | ConvertTo-Json -Compress
    exit 1
}

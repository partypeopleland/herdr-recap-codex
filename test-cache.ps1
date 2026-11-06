$ErrorActionPreference = 'Stop'
$root = Join-Path $env:TEMP ("herdr-recap-codex-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$oldHome, $oldLocal, $oldPath, $oldCalls = $env:CODEX_HOME, $env:LOCALAPPDATA, $env:PATH, $env:FAKE_CALLS
try {
    $env:CODEX_HOME = Join-Path $root 'codex'
    $env:LOCALAPPDATA = Join-Path $root 'local'
    $env:FAKE_CALLS = Join-Path $root 'calls.txt'
    $bin = Join-Path $root 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    $env:PATH = "$bin;$oldPath"
    $id = [guid]::NewGuid().ToString()
    $sessions = Join-Path $env:CODEX_HOME 'sessions\2026\11\06'
    New-Item -ItemType Directory -Force -Path $sessions | Out-Null
    $transcript = Join-Path $sessions "rollout-test-$id.jsonl"
    [IO.File]::WriteAllText($transcript, 'test session')
    $fake = @'
@echo off
setlocal
echo call>>"%FAKE_CALLS%"
:loop
if "%~1"=="-o" (echo fake summary>"%~2" & exit /b 0)
if "%~1"=="" exit /b 1
shift
goto loop
'@
    [IO.File]::WriteAllText((Join-Path $bin 'codex.cmd'), $fake)
    $backend = Join-Path $PSScriptRoot 'mod\backend.ps1'
    & $backend write $id
    & $backend write $id
    if (-not (Test-Path -LiteralPath $env:FAKE_CALLS)) {
        $errorFile = Join-Path $env:LOCALAPPDATA "HerdrRecapCodex\recaps\$id.error"
        throw "Fake Codex was not called: $(Get-Content -LiteralPath $errorFile -Raw)"
    }
    $calls = @(Get-Content -LiteralPath $env:FAKE_CALLS).Count
    if ($calls -ne 1) { throw "Expected one Codex call for unchanged transcript, got $calls" }
    Add-Content -LiteralPath $transcript -Value 'changed'
    & $backend write $id
    $calls = @(Get-Content -LiteralPath $env:FAKE_CALLS).Count
    if ($calls -ne 2) { throw "Expected one more Codex call after transcript change, got $calls" }
    'cache test: PASS'
} finally {
    $env:CODEX_HOME, $env:LOCALAPPDATA, $env:PATH, $env:FAKE_CALLS = $oldHome, $oldLocal, $oldPath, $oldCalls
    $resolved = [IO.Path]::GetFullPath($root)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

$ErrorActionPreference = 'Stop'
$appHome = Join-Path $HOME '.config\herdr-app'
$target = Join-Path $appHome 'mods\recap-codex'
if (-not (Test-Path -LiteralPath (Join-Path $appHome 'AGENTS.md'))) { throw "Herdr app home not found: $appHome" }
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'mod\*') -Destination $target -Recurse -Force
$keysPath = Join-Path $appHome 'keys.json'
$keys = Get-Content -LiteralPath $keysPath -Raw | ConvertFrom-Json -AsHashtable
if (-not $keys.Contains('global')) { $keys['global'] = @{} }
if ($keys['global']['ctrl-alt-r'] -ne 'mod.open:recap-codex') {
    Copy-Item -LiteralPath $keysPath -Destination ($keysPath + '.before-recap-codex-' + (Get-Date -Format 'yyyyMMddHHmmss'))
    $keys['global']['ctrl-alt-r'] = 'mod.open:recap-codex'
    $json = $keys | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText($keysPath, $json + "`n", [Text.UTF8Encoding]::new($false))
}
& herdr-app check $target
if ($LASTEXITCODE -ne 0) { throw 'Herdr mod check failed' }
"Installed to $target"

# Installs the desktop-control skill into ~/.claude/skills and adds the `dsk` command to PATH.
# Usage (PowerShell):
#   irm https://raw.githubusercontent.com/publisher-web/claude-skills/main/install.ps1 | iex
$ErrorActionPreference = 'Stop'
$base = 'https://raw.githubusercontent.com/publisher-web/claude-skills/main/plugins/desktop-control/skills/desktop-control'
$dest = Join-Path $env:USERPROFILE '.claude\skills\desktop-control'
$bin = Join-Path $env:USERPROFILE '.local\bin'
New-Item -ItemType Directory -Force $dest, $bin | Out-Null

$local = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'plugins\desktop-control\skills\desktop-control' }
foreach ($f in 'SKILL.md', 'desk.ps1', 'DeskNative.cs') {
  $out = Join-Path $dest $f
  if ($local -and (Test-Path (Join-Path $local $f))) { Copy-Item (Join-Path $local $f) $out -Force }
  else { Invoke-WebRequest "$base/$f" -OutFile $out -UseBasicParsing }
  Unblock-File $out
}

# dsk.ps1 (PowerShell) and dsk (Git Bash) entry points
$utf8Bom = New-Object Text.UTF8Encoding $true
[IO.File]::WriteAllText((Join-Path $bin 'dsk.ps1'), @'
$global:LASTEXITCODE = 0
& "$env:USERPROFILE\.claude\skills\desktop-control\desk.ps1" @args
exit $LASTEXITCODE
'@, $utf8Bom)
[IO.File]::WriteAllText((Join-Path $bin 'dsk'), "#!/bin/sh`nDESK_UTF8=1 exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"`$USERPROFILE/.claude/skills/desktop-control/desk.ps1`" `"`$@`"`n", (New-Object Text.UTF8Encoding $false))

$path = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (($path -split ';') -contains $bin)) {
  [Environment]::SetEnvironmentVariable('Path', ($(if ($path) { "$path;" }) + $bin), 'User')
  Write-Host "Added $bin to your user PATH (restart the terminal / Claude Code)."
}
$pol = Get-ExecutionPolicy -Scope CurrentUser
if ($pol -eq 'Undefined' -or $pol -eq 'Restricted') {
  Write-Host "Tip: to call 'dsk' from PowerShell, run: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
}
Write-Host "Installed desktop-control to $dest"

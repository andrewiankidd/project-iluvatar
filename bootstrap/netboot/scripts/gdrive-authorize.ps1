# Google Drive sign-in for arda's backups (VolSync through rclone).
#
# Reads ARDA_GDRIVE_CLIENT_ID and ARDA_GDRIVE_CLIENT_SECRET from .env (your
# own Google Cloud OAuth client, "Desktop app", Drive API enabled, consent
# screen published), runs `rclone authorize` with them and the drive.file
# scope (rclone sees only the files it makes), and writes the token back to
# .env as ARDA_GDRIVE_TOKEN. A browser opens for the Google sign-in.
#
#   .\bootstrap\netboot\scripts\gdrive-authorize.ps1
#   .\bootstrap\netboot\scripts\gdrive-authorize.ps1 -Rclone C:\path\to\rclone.exe
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env'),
    [string]$Rclone
)
$ErrorActionPreference = 'Stop'

if (-not $Rclone) {
    $cmd = Get-Command rclone -ErrorAction SilentlyContinue
    if ($cmd) { $Rclone = $cmd.Source }
}
if (-not $Rclone -or -not (Test-Path $Rclone)) {
    throw "rclone not found: put it on PATH or pass -Rclone <path to rclone.exe>"
}
$EnvFile = (Resolve-Path $EnvFile).Path
$lines = [System.IO.File]::ReadAllLines($EnvFile)

function Get-EnvValue([string]$name) {
    $line = $lines | Where-Object { $_ -like "$name=*" } | Select-Object -First 1
    if (-not $line) { return '' }
    return $line.Substring($name.Length + 1).Trim().Trim("'").Trim('"')
}
$id = Get-EnvValue 'ARDA_GDRIVE_CLIENT_ID'
$secret = Get-EnvValue 'ARDA_GDRIVE_CLIENT_SECRET'
if (-not $id -or -not $secret) {
    throw "Set ARDA_GDRIVE_CLIENT_ID and ARDA_GDRIVE_CLIENT_SECRET in $EnvFile first"
}

# rclone's options as base64 JSON: the client and the scope together.
$opts = @{ client_id = $id; client_secret = $secret; scope = 'drive.file' } | ConvertTo-Json -Compress
$optsB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($opts))

Write-Host "A browser opens: sign in with the Google account for the backups, and allow access."
# rclone logs notices on stderr, which Windows PowerShell turns into errors
# under 'Stop'; they're only notices here.
$ErrorActionPreference = 'Continue'
$out = & $Rclone authorize drive $optsB64 2>&1 | ForEach-Object { "$_" }
$ErrorActionPreference = 'Stop'
$text = $out -join "`n"

# The token: either rclone's wrapped form (base64 JSON with a "token" field,
# between "--->" and "<---End paste") or the token JSON itself.
$token = $null
if ($text -match '--->\s*\n\s*(\S+)\s*\n\s*<---End paste') {
    $blob = $Matches[1].Replace('-', '+').Replace('_', '/')
    while ($blob.Length % 4) { $blob += '=' }
    $wrapped = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($blob)) | ConvertFrom-Json
    $token = $wrapped.token
} elseif ($text -match '(\{"access_token".*?\})\s*$') {
    $token = $Matches[1]
}
if (-not $token -or $token -notmatch '"refresh_token"') {
    Write-Host $text
    throw "No token with a refresh token in rclone's output"
}
if ($token.Contains("'")) { throw "The token contains a single quote; not written" }

$kept = $lines | Where-Object { $_ -notlike 'ARDA_GDRIVE_TOKEN=*' }
$new = @($kept) + "ARDA_GDRIVE_TOKEN='$token'"
# UTF-8 without a byte-order mark, LF line ends: the file is sourced by sh.
[System.IO.File]::WriteAllText($EnvFile, (($new -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "ARDA_GDRIVE_TOKEN written to $EnvFile (with your own client). The lab picks it up within the hour."

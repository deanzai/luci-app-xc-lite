param(
    [string]$TokenFile = (Join-Path (Split-Path -Parent $PSScriptRoot) "github_token.txt"),
    [string]$Remote = "origin",
    [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Test-Path -LiteralPath $TokenFile -PathType Leaf)) {
    throw "Token file not found: $TokenFile"
}

$token = (Get-Content -LiteralPath $TokenFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Token file is empty"
}

$askPass = Join-Path $env:TEMP ("xc-git-askpass-{0}.ps1" -f ([guid]::NewGuid().ToString("N")))
$askPassBody = @'
param([string]$Prompt)
if ($Prompt -match '(?i)username') { 'x-access-token' } else { [Environment]::GetEnvironmentVariable('XC_GIT_TOKEN') }
'@

try {
    Set-Content -LiteralPath $askPass -Value $askPassBody -Encoding utf8 -NoNewline
    $env:XC_GIT_TOKEN = $token
    $env:GIT_ASKPASS = $askPass
    $env:GIT_TERMINAL_PROMPT = "0"
    git -C $repo push $Remote $Branch
    if ($LASTEXITCODE -ne 0) { throw "git push failed with exit code $LASTEXITCODE" }
}
finally {
    Remove-Item Env:XC_GIT_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_ASKPASS -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $askPass -Force -ErrorAction SilentlyContinue
}

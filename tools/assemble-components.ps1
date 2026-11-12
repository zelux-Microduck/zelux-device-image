param(
    [string]$Agent = (Join-Path $PSScriptRoot '..\..\zelux-device-agent'),
    [string]$Studio = (Join-Path $PSScriptRoot '..\..\zelux-studio'),
    [string]$Output = (Join-Path $PSScriptRoot '..\components')
)

$ErrorActionPreference = 'Stop'
$agentRoot = (Resolve-Path -LiteralPath $Agent).Path
$studioRoot = (Resolve-Path -LiteralPath $Studio).Path
$outputRoot = [IO.Path]::GetFullPath($Output)
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $outputRoot.StartsWith($repoRoot + [IO.Path]::DirectorySeparatorChar)) {
    throw "Output 必须位于镜像仓库内：$repoRoot"
}

if (Test-Path -LiteralPath $outputRoot) {
    Remove-Item -LiteralPath $outputRoot -Recurse -Force
}
New-Item -ItemType Directory -Path (Join-Path $outputRoot 'software') -Force | Out-Null
Copy-Item -Path (Join-Path $agentRoot 'software\*') -Destination (Join-Path $outputRoot 'software') -Recurse
New-Item -ItemType Directory -Path (Join-Path $outputRoot 'software\web') -Force | Out-Null
Get-ChildItem -LiteralPath $studioRoot -Force |
    Where-Object { $_.Name -ne '.git' } |
    Copy-Item -Destination (Join-Path $outputRoot 'software\web') -Recurse

Get-ChildItem -Path $outputRoot -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force
Get-ChildItem -Path $outputRoot -Recurse -File -Filter '*.pyc' | Remove-Item -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'components.lock.yaml') -Destination $outputRoot
Write-Host "Components assembled: $outputRoot"

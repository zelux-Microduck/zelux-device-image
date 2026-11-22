param(
    [string]$Agent = (Join-Path $PSScriptRoot '..\..\zelux-device-agent'),
    [string]$Studio = (Join-Path $PSScriptRoot '..\..\zelux-studio'),
    [string]$Drivers = (Join-Path $PSScriptRoot '..\..\zelux-device-drivers'),
    [string]$Output = (Join-Path $PSScriptRoot '..\components'),
    [Parameter(Mandatory=$true)][string]$RobotdReleaseDir,
    [Parameter(Mandatory=$true)][string]$RobotdManifestSha256
)

$ErrorActionPreference = 'Stop'
$agentRoot = (Resolve-Path -LiteralPath $Agent).Path
$studioRoot = (Resolve-Path -LiteralPath $Studio).Path
$driversRoot = (Resolve-Path -LiteralPath $Drivers).Path
$outputRoot = [IO.Path]::GetFullPath($Output)
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $outputRoot.StartsWith($repoRoot + [IO.Path]::DirectorySeparatorChar)) {
    throw "Output 必须位于镜像仓库内：$repoRoot"
}

if (Test-Path -LiteralPath $outputRoot) {
    throw 'Output 已存在；请选择新的装配目录，避免覆盖已有组件'
}
New-Item -ItemType Directory -Path (Join-Path $outputRoot 'software') -Force | Out-Null
Copy-Item -Path (Join-Path $agentRoot 'software\*') -Destination (Join-Path $outputRoot 'software') -Recurse
Copy-Item -LiteralPath (Join-Path $driversRoot 'src\zelux_drivers') -Destination (Join-Path $outputRoot 'software') -Recurse
New-Item -ItemType Directory -Path (Join-Path $outputRoot 'software\zelux-fan') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot '..\zelux-fan\fanctl') -Destination (Join-Path $outputRoot 'software\zelux-fan\fanctl')
New-Item -ItemType Directory -Path (Join-Path $outputRoot 'software\systemd') -Force | Out-Null
Copy-Item -Path (Join-Path $repoRoot 'overlay\etc\systemd\system\*.service') -Destination (Join-Path $outputRoot 'software\systemd') -Force
New-Item -ItemType Directory -Path (Join-Path $outputRoot 'software\web') -Force | Out-Null
Get-ChildItem -LiteralPath $studioRoot -Force |
    Where-Object { $_.Name -notin @('.git', '.codegraph', 'node_modules') } |
    Copy-Item -Destination (Join-Path $outputRoot 'software\web') -Recurse

Get-ChildItem -Path $outputRoot -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force
Get-ChildItem -Path $outputRoot -Recurse -File -Filter '*.pyc' | Remove-Item -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'components.lock.yaml') -Destination $outputRoot
python (Join-Path $PSScriptRoot 'robotd_component.py') assemble --source $RobotdReleaseDir --manifest-sha256 $RobotdManifestSha256 --output (Join-Path $outputRoot 'robotd') --lock (Join-Path $repoRoot 'components.lock.yaml')
if ($LASTEXITCODE -ne 0) { throw 'robotd assembly failed' }
Copy-Item -LiteralPath (Join-Path $repoRoot 'components.lock.yaml') -Destination $outputRoot -Force
Write-Host "Components assembled: $outputRoot"

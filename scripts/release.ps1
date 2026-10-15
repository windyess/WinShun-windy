param(
    [switch] $Publish,
    [switch] $SkipTests,
    [string] $QtDir = $env:QTDIR,
    [string] $Iscc = $env:ISCC
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$cmake = Get-Content (Join-Path $root 'CMakeLists.txt') -Raw
if ($cmake -notmatch 'project\(WinShun\s+VERSION\s+(\d+\.\d+\.\d+)') {
    throw 'No project(VERSION) in CMakeLists.txt'
}

$version = $Matches[1]
$tag = "v$version"
$notes = Join-Path $root "docs\release-notes\$tag.md"

if ($Publish -and -not (Test-Path $notes)) {
    throw "Write the release notes first: $notes"
}

Write-Host "WinShun $version"

$running = Get-Process WinShun -ErrorAction SilentlyContinue
if ($running) {
    throw 'Quit WinShun first: dist\WinShun is about to be replaced.'
}

if (-not $Iscc) {
    $Iscc = @(
        Get-ChildItem "$env:LOCALAPPDATA\Programs\Inno Setup*\ISCC.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending
        Get-Item "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" -ErrorAction SilentlyContinue
        Get-Item "$env:ProgramFiles\Inno Setup 6\ISCC.exe" -ErrorAction SilentlyContinue
    ) | Select-Object -First 1 -ExpandProperty FullName
}

if (-not $Iscc -or -not (Test-Path $Iscc)) {
    throw 'Inno Setup 6.5 or later is required.'
}

$buildArgs = @{
    Deploy = $true
    SkipTests = $SkipTests
}

if ($PSBoundParameters.ContainsKey('QtDir')) {
    $buildArgs.QtDir = $QtDir
}

& (Join-Path $PSScriptRoot 'build.ps1') @buildArgs

$dist = Join-Path $root 'dist'
$deployDir = Join-Path $dist 'WinShun'
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $deployDir 'LICENSE.txt')

$setup = Join-Path $dist "WinShun-$version-x64-setup.exe"

& $Iscc `
    /Q `
    "/DAppVersion=$version" `
    "/DSourceDir=$deployDir" `
    "/DOutputDir=$dist" `
    (Join-Path $root 'installer\WinShun.iss')

if ($LASTEXITCODE -or -not (Test-Path $setup)) {
    throw 'Inno Setup failed'
}

Write-Host "Packaged $setup"

$portable = Join-Path $dist "WinShun-$version-x64-portable.zip"
Remove-Item $portable -ErrorAction SilentlyContinue

$stage = Join-Path ([IO.Path]::GetTempPath()) "WinShun-portable-$version"
if (Test-Path $stage) {
    Remove-Item $stage -Recurse -Force
}

New-Item -ItemType Directory $stage | Out-Null
Copy-Item $deployDir $stage -Recurse

$dataDir = Join-Path $stage 'WinShun\data'
New-Item -ItemType Directory $dataDir | Out-Null

Copy-Item `
    (Join-Path $root 'installer\portable-data-README.txt') `
    (Join-Path $dataDir 'README.txt')

Compress-Archive `
    -Path (Join-Path $stage 'WinShun') `
    -DestinationPath $portable `
    -CompressionLevel Optimal

Remove-Item $stage -Recurse -Force
Write-Host "Packaged $portable"

$sums = Join-Path $dist 'SHA256SUMS.txt'
$lines = foreach ($file in $setup, $portable) {
    "$((Get-FileHash $file -Algorithm SHA256).Hash.ToLower())  $(Split-Path $file -Leaf)"
}

Set-Content $sums ($lines -join "`n") -Encoding ascii -NoNewline
Get-Content $sums

if ($Publish) {
    gh release create $tag $setup $portable $sums `
        --repo LingCore/WinShun `
        --title "WinShun $version" `
        --notes-file $notes `
        --target main

    if ($LASTEXITCODE) {
        throw 'gh release create failed'
    }
}

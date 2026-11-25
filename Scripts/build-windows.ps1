param([string]$Dotnet = 'dotnet', [string]$CoreArchive, [string]$CoreSourceArchive, [string]$Go = 'go')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = '1.14.4'
$coreName = "sing-box-$version-windows-amd64"
$coreHash = '99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df'
$sourceHash = '0958ccd23b1ea9a141d715d15478b1e040fd04bcca19d8ff5529636b1b753e18'
$build = Join-Path $root '.build\windows'
$out = Join-Path $build ('Byway-win-x64-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $out -Force | Out-Null

function Read-CoreArchive([string]$Path, [string]$DefaultName, [string]$Url, [string]$Hash) {
    if (!$Path) {
        $Path = Join-Path $build $DefaultName
    }
    if (!(Test-Path -LiteralPath $Path)) {
        $download = "$Path.$PID.tmp"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $download
            if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $Hash) { throw "Archive hash mismatch: $DefaultName." }
            Move-Item -LiteralPath $download -Destination $Path
        } finally {
            if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download }
        }
    }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Hash) { throw "Archive hash mismatch: $Path." }
    return (Resolve-Path -LiteralPath $Path).Path
}

$CoreArchive = Read-CoreArchive $CoreArchive "$coreName.zip" "https://github.com/SagerNet/sing-box/releases/download/v$version/$coreName.zip" $coreHash
$CoreSourceArchive = Read-CoreArchive $CoreSourceArchive "sing-box-v$version.tar.gz" "https://codeload.github.com/SagerNet/sing-box/tar.gz/refs/tags/v$version" $sourceHash

$payload = Join-Path $out 'app'
& $Dotnet publish (Join-Path $root 'Windows\Byway.csproj') -c Release -r win-x64 --self-contained -o $payload `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:DebugType=None
if ($LASTEXITCODE -ne 0) { throw 'Byway publish failed.' }

$work = Join-Path ([IO.Path]::GetTempPath()) ('Byway-core-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    & tar.exe -xzf $CoreSourceArchive -C $work
    if ($LASTEXITCODE -ne 0) { throw 'Could not extract sing-box source.' }
    Push-Location (Join-Path $work "sing-box-$version")
    $goEnv = @{ GOOS = $env:GOOS; GOARCH = $env:GOARCH; CGO_ENABLED = $env:CGO_ENABLED }
    try {
        & git apply (Join-Path $root 'Vendor\sing-box-preserve-domain.patch')
        if ($LASTEXITCODE -ne 0) { throw 'Could not apply the sing-box routing patch.' }
        & git apply (Join-Path $root 'Vendor\byway-tailscale.patch')
        if ($LASTEXITCODE -ne 0) { throw 'Could not apply the private network patch.' }
        $tailscaleVersion = & $Go list -m -f '{{.Version}}' github.com/sagernet/tailscale
        if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the pinned Tailscale module.' }
        $tailscaleModule = (& $Go mod download -json "github.com/sagernet/tailscale@$tailscaleVersion") | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or !$tailscaleModule.Dir) { throw 'Could not download the pinned Tailscale module.' }
        $tailscaleWork = Join-Path $work 'tailscale'
        Copy-Item -LiteralPath $tailscaleModule.Dir -Destination $tailscaleWork -Recurse
        Push-Location $tailscaleWork
        try {
            & git apply (Join-Path $root 'Vendor\byway-tailscale-map.patch')
            if ($LASTEXITCODE -ne 0) { throw 'Could not apply the Tailscale DERP policy patch.' }
        } finally { Pop-Location }
        & $Go mod edit -replace "github.com/sagernet/tailscale=$tailscaleWork"
        if ($LASTEXITCODE -ne 0) { throw 'Could not select the patched Tailscale module.' }
        Copy-Item -LiteralPath (Join-Path $root 'Vendor\byway_private_endpoint.go') -Destination 'protocol\tailscale'
        Copy-Item -LiteralPath (Join-Path $root 'Vendor\byway_private_clash.go') -Destination 'experimental\clashapi'
        $tags = (Get-Content -Raw 'release/DEFAULT_BUILD_TAGS_WINDOWS').Trim()
        $flags = (Get-Content -Raw 'release/LDFLAGS').Trim()
        $env:GOOS = 'windows'
        $env:GOARCH = 'amd64'
        $env:CGO_ENABLED = '0'
        & $Go build -trimpath -buildvcs=false -tags $tags -ldflags "$flags -X github.com/sagernet/sing-box/constant.Version=$version -s -w" `
            -o (Join-Path $payload 'sing-box.exe') ./cmd/sing-box
        if ($LASTEXITCODE -ne 0) { throw 'sing-box build failed.' }
    } finally {
        foreach ($key in $goEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $goEnv[$key], 'Process') }
        Pop-Location
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($CoreArchive)
try {
    foreach ($name in 'libcronet.dll', 'LICENSE') {
        $entry = $archive.GetEntry("$coreName/$name")
        if (!$entry) { throw "Missing core archive entry $name." }
        $destination = if ($name -eq 'LICENSE') { 'sing-box.LICENSE' } else { $name }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $payload $destination))
    }
} finally { $archive.Dispose() }

Copy-Item -LiteralPath (Join-Path $root 'Windows\Install.ps1') -Destination $out
$zip = "$out.zip"
[IO.Compression.ZipFile]::CreateFromDirectory($out, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
Write-Output $zip

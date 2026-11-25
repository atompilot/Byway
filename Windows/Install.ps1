param([switch]$AllowLanApi)

$ErrorActionPreference = 'Stop'
$payload = Join-Path $PSScriptRoot 'app'
$executable = Join-Path $payload 'Byway.exe'
if (!(Test-Path -LiteralPath $executable) -or !(Test-Path -LiteralPath (Join-Path $payload 'sing-box.exe'))) {
    throw 'Extract the complete Byway package before installing.'
}
$version = [Diagnostics.FileVersionInfo]::GetVersionInfo($executable).FileVersion
$files = @(Get-ChildItem -LiteralPath $payload -File -Recurse | Sort-Object FullName | ForEach-Object {
    [pscustomobject]@{
        RelativePath = $_.FullName.Substring($payload.Length + 1)
        Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
})
$manifest = ($files | ForEach-Object { "{0}`t{1}" -f $_.Hash, $_.RelativePath }) -join "`n"
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
    $digest = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($manifest))
    $revision = [BitConverter]::ToString($digest).Replace('-', '').Substring(0, 12).ToLowerInvariant()
} finally { $sha256.Dispose() }
$apps = Join-Path $env:LOCALAPPDATA 'Byway\Apps'
$destination = Join-Path $apps "$version-$revision"
New-Item -ItemType Directory -Path $apps -Force | Out-Null
if (!(Test-Path -LiteralPath $destination)) {
    $stage = Join-Path $apps ([Guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -LiteralPath $payload -Destination $stage -Recurse
        try { [IO.Directory]::Move($stage, $destination) }
        catch [IO.IOException] {
            if (!(Test-Path -LiteralPath $destination -PathType Container)) { throw }
        }
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse }
    }
}
foreach ($file in $files) {
    $installed = Join-Path $destination $file.RelativePath
    if (!(Test-Path -LiteralPath $installed) -or (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -ne $file.Hash) {
        throw "Installed copy differs from the package at $installed."
    }
}

$installedExe = Join-Path $destination 'Byway.exe'
$programs = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
$shortcut = Join-Path $programs 'Byway.lnk'
$shell = New-Object -ComObject WScript.Shell
$tempLink = Join-Path $programs ("Byway." + [Guid]::NewGuid().ToString('N') + '.lnk')
try {
    $link = $shell.CreateShortcut($tempLink)
    $link.TargetPath = $installedExe
    $link.WorkingDirectory = $destination
    $link.IconLocation = $installedExe
    $link.Save()
    if (Test-Path -LiteralPath $shortcut) {
        $backup = "$shortcut.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss_fff')"
        [IO.File]::Replace($tempLink, $shortcut, $backup)
    } else {
        [IO.File]::Move($tempLink, $shortcut)
    }
} finally {
    if (Test-Path -LiteralPath $tempLink) { Remove-Item -LiteralPath $tempLink }
}
if ($AllowLanApi) {
    $firewall = Start-Process -FilePath $installedExe -ArgumentList '--authorize-lan-firewall' -Wait -PassThru
    if ($firewall.ExitCode -ne 0) { throw 'Byway LAN API firewall authorization requires Administrator permission.' }
}
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startup = (Get-ItemProperty -Path $run -Name Byway -ErrorAction SilentlyContinue).Byway
if ($startup -and $startup -match '^"([^"]+)" --login$' -and
    $Matches[1].StartsWith($apps + '\', [StringComparison]::OrdinalIgnoreCase) -and
    $Matches[1].EndsWith('\Byway.exe', [StringComparison]::OrdinalIgnoreCase)) {
    Set-ItemProperty -Path $run -Name Byway -Value ('"' + $installedExe + '" --login')
}
Write-Output $installedExe

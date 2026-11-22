# Installs a downloaded Unified Slicer package over the install folder (see docs/HLSD/updater.md).
# The app's install helper starts it once the app has exited, with administrator rights when the
# install folder needs them. It ships inside the install folder, so under Program Files nobody
# without administrator rights can change it. Exit code 0 means installed; the reason for a failure
# is the last line of apply_update.log in the install folder.
param(
    [Parameter(Mandatory)][string]$Zip,    # the package, in the user's data folder
    [Parameter(Mandatory)][string]$Hash,   # its SHA-256, from the checksum file the app verified
    [Parameter(Mandatory)][string]$Dest,   # the install folder
    [Parameter(Mandatory)][string]$Exe     # file name of the app's executable
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $Dest 'apply_update.log'
function Log($m) { Add-Content -LiteralPath $log -Value ((Get-Date -Format s) + ' ' + $m) }
Set-Content -LiteralPath $log -Value ((Get-Date -Format s) + ' starting')

# Everything is checked and unpacked inside the install folder, which a process without the same
# rights as this one cannot change between the check and the copy. Nothing in the user's data
# folder is written or deleted from here: the helper that started this script does that.
$work = Join-Path $Dest ('.update-' + [guid]::NewGuid().ToString('N'))
$code = 1
try {
    New-Item -ItemType Directory -Path $work | Out-Null
    $package = Join-Path $work 'package.zip'
    Copy-Item -LiteralPath $Zip -Destination $package
    $actual = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    if ($actual -ne $Hash) { throw 'the package does not match its verified checksum' }

    $stage = Join-Path $work 'files'
    Expand-Archive -LiteralPath $package -DestinationPath $stage
    $src = $stage
    if (-not (Test-Path -LiteralPath (Join-Path $src $Exe))) {
        $dirs = @(Get-ChildItem -LiteralPath $src -Directory)
        if ($dirs.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $dirs[0].FullName $Exe))) { $src = $dirs[0].FullName }
        else { throw "the package has no $Exe" }
    }

    # The new version's files, relative to the install folder.
    $srcRoot = (Get-Item -LiteralPath $src).FullName.TrimEnd('\') + '\'
    $files = @(Get-ChildItem -LiteralPath $src -Recurse -File | ForEach-Object { $_.FullName.Substring($srcRoot.Length) })

    robocopy $src $Dest /E /R:15 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "copying the files failed (robocopy $LASTEXITCODE)" }

    # Remove what the previous version installed and this one no longer ships. The manifest lists
    # what the last update installed; before the first one, only the resources folder is known to
    # belong to the app (the folder may also hold the uninstaller or a portable data_dir).
    $manifest = Join-Path $Dest '.update-manifest.txt'
    $destRoot = (Get-Item -LiteralPath $Dest).FullName.TrimEnd('\') + '\'
    if (Test-Path -LiteralPath $manifest) {
        $old = @(Get-Content -LiteralPath $manifest)
    } else {
        $resources = Join-Path $Dest 'resources'
        $old = @()
        if (Test-Path -LiteralPath $resources) {
            $old = @(Get-ChildItem -LiteralPath $resources -Recurse -File | ForEach-Object { $_.FullName.Substring($destRoot.Length) })
        }
    }
    $keep = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $files) { [void]$keep.Add($f) }
    foreach ($rel in $old) {
        if ([string]::IsNullOrWhiteSpace($rel) -or $keep.Contains($rel) -or $rel.Contains('..') -or [System.IO.Path]::IsPathRooted($rel)) { continue }
        Remove-Item -LiteralPath (Join-Path $Dest $rel) -Force -ErrorAction SilentlyContinue
    }
    Set-Content -LiteralPath $manifest -Value $files

    Log 'installed'
    $code = 0
} catch {
    Log ('failed: ' + $_)
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code

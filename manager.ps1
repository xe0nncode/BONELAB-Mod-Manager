$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Windows.Forms

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsFile = Join-Path $scriptRoot 'manager-settings.json'
$defaultModsPath = Join-Path $env:USERPROFILE 'AppData\LocalLow\Stress Level Zero\BONELAB\Mods'
$modsPath = $defaultModsPath

if (Test-Path -LiteralPath $settingsFile) {
    try {
        $savedSettings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        if ($savedSettings.ModsPath) {
            $modsPath = $savedSettings.ModsPath
        }
    } catch {
        Write-Host 'Could not read saved settings; using the default BONELAB Mods folder.' -ForegroundColor Yellow
    }
}

function Save-Settings {
    @{ ModsPath = $script:modsPath } |
        ConvertTo-Json |
        Set-Content -LiteralPath $script:settingsFile -Encoding UTF8
}

function Select-ModsFolder {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select BONELAB''s Mods folder (or the folder where mods should be installed).'
    $dialog.ShowNewFolderButton = $true
    if (Test-Path -LiteralPath $script:modsPath) {
        $dialog.SelectedPath = $script:modsPath
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:modsPath = $dialog.SelectedPath
        Save-Settings
    }
}

function Get-SafeFolderName([string]$Name) {
    $safeName = $Name -replace '[<>:"/\\|?*]', '_'
    $safeName = $safeName.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        throw 'The mod name is empty or invalid.'
    }
    return $safeName
}

function Expand-SafeZip([string]$ArchivePath, [string]$Destination) {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $root = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName.Replace('/', '\')
            if ([System.IO.Path]::IsPathRooted($entryName) -or $entryName -match '(^|\\)\.\.(\\|$)') {
                throw "Unsafe path in ZIP archive: $($entry.FullName)"
            }
            $outputPath = [System.IO.Path]::GetFullPath((Join-Path $Destination $entryName))
            if (-not $outputPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe path in ZIP archive: $($entry.FullName)"
            }
            if ($entry.FullName.EndsWith('/')) {
                [System.IO.Directory]::CreateDirectory($outputPath) | Out-Null
            } else {
                [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($outputPath)) | Out-Null
                $inputStream = $entry.Open()
                try {
                    $outputStream = [System.IO.File]::Create($outputPath)
                    try {
                        $inputStream.CopyTo($outputStream)
                    } finally {
                        $outputStream.Dispose()
                    }
                } finally {
                    $inputStream.Dispose()
                }
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Install-ModArchive([string]$ArchivePath, [string]$SuggestedName) {
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw 'The selected archive does not exist.'
    }
    if ([System.IO.Path]::GetExtension($ArchivePath) -ine '.zip') {
        throw 'BONELAB mod downloads must be ZIP archives.'
    }

    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ('bonelab-mod-' + [Guid]::NewGuid().ToString('N'))
    $unpacked = Join-Path $stage 'unpacked'
    try {
        [System.IO.Directory]::CreateDirectory($unpacked) | Out-Null
        Expand-SafeZip -ArchivePath $ArchivePath -Destination $unpacked
        $children = @(Get-ChildItem -LiteralPath $unpacked -Force)
        if ($children.Count -eq 0) {
            throw 'The ZIP archive is empty.'
        }

        $source = $unpacked
        if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
            $source = $children[0].FullName
        }

        $folderName = Get-SafeFolderName $SuggestedName
        $installPath = Join-Path $script:modsPath $folderName
        if (Test-Path -LiteralPath $installPath) {
            throw "A mod folder named '$folderName' already exists. Rename or remove it before installing this mod."
        }

        [System.IO.Directory]::CreateDirectory($script:modsPath) | Out-Null
        [System.IO.Directory]::CreateDirectory($installPath) | Out-Null
        Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $installPath -Recurse -Force
        Write-Host "Installed '$folderName' to $installPath" -ForegroundColor Green
    } finally {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force
        }
    }
}

function Get-NameFromUrl([uri]$Uri) {
    $fileName = [System.IO.Path]::GetFileName($Uri.AbsolutePath)
    $name = [System.IO.Path]::GetFileNameWithoutExtension([uri]::UnescapeDataString($fileName))
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = 'BONELAB-Mod-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    }
    return $name
}

function Download-Mod {
    $url = Read-Host 'Direct URL to the mod ZIP archive'
    $uri = $null
    if (-not [uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
        throw 'Enter a valid http or https download URL.'
    }

    $downloadFolder = Join-Path $scriptRoot 'Downloads'
    [System.IO.Directory]::CreateDirectory($downloadFolder) | Out-Null
    $archivePath = Join-Path $downloadFolder (([Guid]::NewGuid().ToString('N')) + '.zip')
    try {
        Write-Host 'Downloading mod archive...'
        Invoke-WebRequest -Uri $uri -OutFile $archivePath -UseBasicParsing
        Install-ModArchive -ArchivePath $archivePath -SuggestedName (Get-NameFromUrl $uri)
    } finally {
        if (Test-Path -LiteralPath $archivePath) {
            Remove-Item -LiteralPath $archivePath -Force
        }
    }
}

function Import-LocalMod {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Select a BONELAB mod ZIP archive'
    $dialog.Filter = 'ZIP archives (*.zip)|*.zip|All files (*.*)|*.*'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($dialog.FileName)
        Install-ModArchive -ArchivePath $dialog.FileName -SuggestedName $name
    }
}

while ($true) {
    Clear-Host
    Write-Host 'BONELAB Mod Manager' -ForegroundColor Cyan
    Write-Host "Install folder: $modsPath"
    Write-Host ''
    Write-Host '1. Download and install from a direct ZIP URL'
    Write-Host '2. Import a downloaded ZIP archive'
    Write-Host '3. Change BONELAB Mods folder'
    Write-Host '4. Open BONELAB Mods folder'
    Write-Host '5. Exit'
    $choice = Read-Host 'Choose an option'

    try {
        switch ($choice) {
            '1' { Download-Mod }
            '2' { Import-LocalMod }
            '3' { Select-ModsFolder }
            '4' {
                [System.IO.Directory]::CreateDirectory($modsPath) | Out-Null
                Start-Process explorer.exe -ArgumentList @($modsPath)
            }
            '5' { return }
            default { Write-Host 'Choose an option from 1 to 5.' -ForegroundColor Yellow }
        }
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }

    if ($choice -ne '5') {
        Read-Host 'Press Enter to continue' | Out-Null
    }
}
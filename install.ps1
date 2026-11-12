# Installs larperCord for the current user, no administrator needed.
#   irm https://raw.githubusercontent.com/RshaCuDeVidro/larperCord/main/install.ps1 | iex
#   Uninstall: & ([scriptblock]::Create((irm .../install.ps1))) -Uninstall
#   Also delete settings, cache, FFmpeg, sounds and saved accounts: the same with -Purge
param([switch]$Uninstall, [switch]$Purge)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo = 'RshaCuDeVidro/larperCord'
$dir = Join-Path $env:LOCALAPPDATA 'Programs\larperCord'
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'larperCord.lnk'

if ($Uninstall -or $Purge) {
    Get-Process larpercord -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
    if (-not $Purge) {
        Write-Host 'larperCord removed. Your settings are still in %APPDATA%\larpercord (-Purge deletes them too).'
        return
    }
    Start-Sleep -Milliseconds 500
    Remove-Item (Join-Path $env:APPDATA 'larpercord') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:LOCALAPPDATA 'larpercord') -Recurse -Force -ErrorAction SilentlyContinue
    # Saved accounts: one Credential Manager entry each (larperCord/account/<id>). Through the
    # API, since cmdkey's output changes with the Windows language.
    if (-not ('LarperCordPurge.Cred' -as [type])) {
        Add-Type -Namespace LarperCordPurge -Name Cred -MemberDefinition @'
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CredEnumerate(string filter, int flags, out int count, out IntPtr credentials);
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CredDelete(string target, int type, int flags);
[DllImport("advapi32.dll")]
public static extern void CredFree(IntPtr buffer);
'@
    }
    $count = 0
    $list = [IntPtr]::Zero
    if ([LarperCordPurge.Cred]::CredEnumerate('larperCord/account/*', 0, [ref]$count, [ref]$list)) {
        $marshal = [Runtime.InteropServices.Marshal]
        # CREDENTIALW: Flags and Type (4 bytes each), then TargetName.
        $targets = for ($i = 0; $i -lt $count; $i++) {
            $marshal::PtrToStringUni($marshal::ReadIntPtr($marshal::ReadIntPtr($list, $i * [IntPtr]::Size), 8))
        }
        [LarperCordPurge.Cred]::CredFree($list)
        foreach ($t in $targets) { [void][LarperCordPurge.Cred]::CredDelete($t, 1, 0) }
    }
    Write-Host 'larperCord removed, with its settings, cache, FFmpeg, sounds and saved accounts.'
    return
}

$base = "https://github.com/$repo/releases/latest/download"
$tmp = Join-Path $env:TEMP ("larpercord-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Write-Host 'Downloading the latest version...'
    Invoke-WebRequest "$base/SHA256SUMS" -OutFile "$tmp\SHA256SUMS" -UseBasicParsing
    $files = @{
        'larpercord-windows-x86_64.exe' = 'larpercord.exe'
        'SDL3.dll' = 'SDL3.dll'
        'libcurl-x64.dll' = 'libcurl-x64.dll'
        'libcrypto-3-x64.dll' = 'libcrypto-3-x64.dll'
    }
    $sums = @{}
    foreach ($line in Get-Content "$tmp\SHA256SUMS") {
        $parts = $line -split '\s+\*?', 2
        if ($parts.Count -eq 2) { $sums[$parts[1]] = $parts[0] }
    }
    foreach ($asset in $files.Keys) {
        Invoke-WebRequest "$base/$asset" -OutFile "$tmp\$asset" -UseBasicParsing
        $hash = (Get-FileHash "$tmp\$asset" -Algorithm SHA256).Hash
        if (-not $sums.ContainsKey($asset) -or $hash -ne $sums[$asset].ToUpper()) {
            throw "$asset does not match SHA256SUMS. Nothing was installed."
        }
    }
    Get-Process larpercord -ErrorAction SilentlyContinue | Stop-Process -Force
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($asset in $files.Keys) {
        Copy-Item "$tmp\$asset" (Join-Path $dir $files[$asset]) -Force
    }
    $wsh = New-Object -ComObject WScript.Shell
    $link = $wsh.CreateShortcut($shortcut)
    $link.TargetPath = Join-Path $dir 'larpercord.exe'
    $link.WorkingDirectory = $dir
    $link.Save()
    Write-Host 'Done. Open larperCord from the Start menu.'
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

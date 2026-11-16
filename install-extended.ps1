# Extended installer: everything install.ps1 does, then fills an empty plugins
# directory with the web plugin and an empty providers or themes directory
# with the default catalog. A directory that already has entries is never
# touched, so running this again is safe.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repository = "YELANDAOKONG/CrystalCode"
$pluginRepository = "YELANDAOKONG/CrystalCode.Plugins.Web"
$pluginDirectoryName = "web"
$scriptsBase = "https://raw.githubusercontent.com/YELANDAOKONG/CrystalCode.Scripts/master"
$defaultsBase = "https://raw.githubusercontent.com/YELANDAOKONG/CrystalCode.Defaults/master"
$crystalHome = if (-not [string]::IsNullOrWhiteSpace($env:CRYSTAL_HOME)) { $env:CRYSTAL_HOME } else { Join-Path $HOME ".crystal" }
$ExtrasFailed = 0
$installDirectory = Join-Path $HOME ".crystal/binaries/code"
$binaryName = "CrystalCode.exe"

# Mineral palette from CrystalCode.Display Theme: grey42, lightsteelblue, indianred.
# Code points keep this file ASCII so Windows PowerShell 5.1 does not depend on a BOM.
$Esc = [char]27
$GlyphFilled = [string][char]0x2501
$GlyphEmpty = [string][char]0x2500
$GlyphDownRight = [string][char]0x250C
$GlyphDownLeft = [string][char]0x2510
$GlyphUpRight = [string][char]0x2514
$GlyphUpLeft = [string][char]0x2518
$GlyphVertical = [string][char]0x2502

$Styled = $false
$CursorHidden = $false
$Muted = ""
$Accent = ""
$FailColor = ""
$Reset = ""
$LastPercent = -1

function Restore-Cursor {
    if (-not $script:CursorHidden) {
        return
    }

    [Console]::Write("$script:Esc[?25h")
    $script:CursorHidden = $false
}

function Fail([string]$message) {
    if ($script:CursorHidden) {
        [Console]::Write("`n")
    }

    Restore-Cursor
    if ($script:Styled -and -not [Console]::IsErrorRedirected) {
        throw ($script:FailColor + $message + $script:Reset)
    }

    throw $message
}

function Enable-VirtualTerminal {
    try {
        if (-not ("CrystalCode.Install.ConsoleMode" -as [type])) {
            Add-Type -Namespace CrystalCode.Install -Name ConsoleMode -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
"@
        }

        $console = [CrystalCode.Install.ConsoleMode]
        $handle = $console::GetStdHandle(-11)
        $mode = [uint32]0
        if ($console::GetConsoleMode($handle, [ref]$mode)) {
            [void]$console::SetConsoleMode($handle, ($mode -bor 4))
        }
    }
    catch {
        # The host already accepts ANSI, or it does not expose the console mode.
    }
}

function Write-ProgressBar([long]$received, [long]$total) {
    if ($total -le 0) {
        return
    }

    $width = 50
    $percent = [int](($received * 100) / $total)
    if ($percent -gt 100) {
        $percent = 100
    }

    if ($percent -eq $script:LastPercent) {
        return
    }

    $script:LastPercent = $percent
    $on = [int](($percent * $width) / 100)
    $off = $width - $on
    $bar = $script:Accent + ($script:GlyphFilled * $on) + ($script:GlyphEmpty * $off) + (" {0,3}%" -f $percent) + $script:Reset
    [Console]::Write("`r" + $bar)
}

function Write-Card([bool]$addedToPath, [string]$archiveName, [string]$installDirectory) {
    $rule = $script:GlyphEmpty * 9
    $docsUrl = "https://github.com/$repository/blob/master/docs/user-guide.md"
    Write-Host ""
    Write-Host ($script:Muted + $script:GlyphDownRight + $rule + $script:GlyphDownLeft + $script:Reset)
    Write-Host ($script:Muted + $script:GlyphVertical + " " + $script:Accent + "crystal" + $script:Muted + " " + $script:GlyphVertical + $script:Reset)
    Write-Host ($script:Muted + $script:GlyphUpRight + $rule + $script:GlyphUpLeft + $script:Reset)
    Write-Host ""
    Write-Host ("Installed $archiveName to " + $script:Accent + $installDirectory + $script:Reset)
    if ($addedToPath) {
        Write-Host ("Added " + $script:Accent + $installDirectory + $script:Reset + " to the user PATH.")
    }
    else {
        Write-Host ($script:Accent + $installDirectory + $script:Reset + " is already configured in the user PATH.")
    }

    Write-Host "Open a new terminal to use CrystalCode from any directory."
    Write-Host ("Start Crystal Code with: " + $script:Accent + "CrystalCode" + $script:Reset)
    Write-Host ""
    Write-Host ($script:Accent + "cd <project>" + $script:Reset + "  " + $script:Muted + "# Open a repository" + $script:Reset)
    Write-Host ($script:Accent + "CrystalCode" + $script:Reset + "   " + $script:Muted + "# Start Crystal Code" + $script:Reset)
    Write-Host ""
    Write-Host ($script:Muted + "For more information visit " + $script:Reset + $docsUrl)
    Write-Host ""
}

function Add-UserPath([string]$directory) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $pathEntries = @()

    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $pathEntries = $userPath -split ";" | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    }

    if ($pathEntries -contains $directory) {
        if (-not $script:Styled) {
            Write-Host "$directory is already configured in the user PATH."
        }

        return $false
    }

    $updatedPath = if ([string]::IsNullOrWhiteSpace($userPath)) {
        $directory
    }
    else {
        "$userPath;$directory"
    }

    [Environment]::SetEnvironmentVariable("Path", $updatedPath, "User")
    if (-not $script:Styled) {
        Write-Host "Added $directory to the user PATH."
    }

    return $true
}

function Enable-ArchiveDownload {
    if ("CrystalCode.Install.ArchiveDownload" -as [type]) {
        return
    }

    # The transfer runs in C#. A PowerShell event handler has no runspace
    # on the thread that reports download progress, and that terminates the host.
    if (-not ("System.Net.Http.HttpClient" -as [type])) {
        Add-Type -AssemblyName System.Net.Http
    }

    $typeSource = @'
using System;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace CrystalCode.Install
{
    public sealed class ArchiveDownload
    {
        private long received;
        private long total;
        public volatile bool Done;
        public string Error;

        public long Received
        {
            get { return Interlocked.Read(ref received); }
        }

        public long Total
        {
            get { return Interlocked.Read(ref total); }
        }

        public void Start(string url, string destination)
        {
            var self = this;
            Task.Run(delegate
            {
                try
                {
                    using (var client = new HttpClient())
                    {
                        client.Timeout = TimeSpan.FromMinutes(15);
                        var response = client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead).GetAwaiter().GetResult();
                        response.EnsureSuccessStatusCode();
                        if (response.Content.Headers.ContentLength.HasValue)
                        {
                            Interlocked.Exchange(ref self.total, response.Content.Headers.ContentLength.Value);
                        }

                        using (var input = response.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
                        using (var output = File.Create(destination))
                        {
                            var buffer = new byte[65536];
                            int read;
                            while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
                            {
                                output.Write(buffer, 0, read);
                                Interlocked.Add(ref self.received, read);
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    self.Error = ex.Message;
                }
                finally
                {
                    self.Done = true;
                }
            });
        }
    }
}
'@
    # Passing ReferencedAssemblies replaces the default compile references.
    # Try the host defaults first, then add HttpClient for Windows PowerShell 5.1.
    try {
        Add-Type -TypeDefinition $typeSource
    }
    catch {
        $references = [System.Collections.Generic.List[string]]::new()
        foreach ($assembly in @(
                [System.Net.Http.HttpClient].Assembly,
                [object].Assembly,
                [System.IO.File].Assembly,
                [System.Threading.Interlocked].Assembly,
                [System.Threading.Tasks.Task].Assembly
            )) {
            if (-not [string]::IsNullOrEmpty($assembly.Location) -and -not $references.Contains($assembly.Location)) {
                [void]$references.Add($assembly.Location)
            }
        }

        Add-Type -TypeDefinition $typeSource -ReferencedAssemblies $references
    }
}

# Downloads the archive with a progress bar. Returns $false on failure so the
# caller picks the message.
function Receive-CrystalArchive([string]$url, [string]$destination, [string]$archiveName) {
    Enable-ArchiveDownload
    $download = [CrystalCode.Install.ArchiveDownload]::new()
    [Console]::Write("$script:Esc[?25l")
    $script:CursorHidden = $true
    try {
        $download.Start($url, $destination)
        while (-not $download.Done) {
            if ($download.Total -gt 0) {
                Write-ProgressBar $download.Received $download.Total
            }

            Start-Sleep -Milliseconds 50
        }

        if (-not [string]::IsNullOrEmpty($download.Error)) {
            Write-Host ""
            return $false
        }

        $finalLength = (Get-Item -LiteralPath $destination).Length
        $script:LastPercent = -1
        Write-ProgressBar $finalLength $finalLength
        Write-Host ""
        return $true
    }
    finally {
        Restore-Cursor
    }
}

# Prints one result line. Kinds: ok, skip, fail. A failure is counted and sent
# to stderr, but it never stops the installer: Crystal Code is already in place.
function Write-Step([string]$kind, [string]$label, [string]$message) {
    switch ($kind) {
        "ok" { $tag = "done"; $color = $script:Accent }
        "skip" { $tag = "skip"; $color = $script:Muted }
        default { $tag = "fail"; $color = $script:FailColor; $script:ExtrasFailed++ }
    }

    $line = "  {0}[{1}]{2} {3,-9} {4}" -f $color, $tag, $script:Reset, $label, $message
    if ($tag -eq "fail") {
        [Console]::Error.WriteLine($line)
    }
    else {
        Write-Host $line
    }
}

function Clear-Lines([int]$count) {
    if ($script:Styled) {
        [Console]::Write("$script:Esc[" + $count + "A`r$script:Esc[J")
    }
}

function Clear-CurrentLine {
    if ($script:Styled) {
        [Console]::Write("`r$script:Esc[2K")
    }
}

# Redraws one inline bar that carries its own label.
function Write-CountBar([string]$label, [int]$received, [int]$total) {
    if (-not $script:Styled) {
        return
    }

    $width = 30
    $on = [int](($received * $width) / $total)
    $bar = ($script:GlyphFilled * $on) + ($script:GlyphEmpty * ($width - $on))
    $text = "`r$script:Esc[2K  " + $script:Muted + "[....]" + $script:Reset + " " + $label.PadRight(9) + " " +
        $script:Accent + $bar + $script:Reset + " $received/$total"
    [Console]::Write($text)
}

# Returns empty for a missing or empty directory, used when it has entries, and
# file when the path exists but is not a directory.
function Get-DirectoryState([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) {
        return "empty"
    }

    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return "file"
    }

    $first = Get-ChildItem -LiteralPath $path -Force | Select-Object -First 1
    if ($null -eq $first) {
        return "empty"
    }

    return "used"
}

# Downloads a small file with up to three attempts. Returns an empty string on
# success and the error message on failure.
function Get-RemoteFile([string]$url, [string]$destination) {
    $previousProgress = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    $lastError = ""
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-WebRequest -Uri $url -OutFile $destination -UseBasicParsing -TimeoutSec 120 | Out-Null
                return ""
            }
            catch {
                $lastError = $_.Exception.Message
                Start-Sleep -Seconds 1
            }
        }
    }
    finally {
        $ProgressPreference = $previousProgress
    }

    if ([string]::IsNullOrEmpty($lastError)) {
        return "The request failed."
    }

    return $lastError
}

# A directory removal that never prompts: it acts only on an empty directory.
function Remove-EmptyDirectory([string]$path) {
    if ((Test-Path -LiteralPath $path -PathType Container) -and
        ($null -eq (Get-ChildItem -LiteralPath $path -Force | Select-Object -First 1))) {
        Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    }
}

# A manifest line must be a plain *.json file name. It becomes a URL segment and
# a path under the target directory, so nothing else is allowed through.
function Test-CatalogFileName([string]$name) {
    return $name -match '^[A-Za-z0-9][A-Za-z0-9._-]*\.json$'
}

# Fills an empty directory with every file named by a manifest. Files go to a
# staging directory first, so a failed download leaves the target untouched and
# a later run tries again.
function Install-Catalog([string]$label, [string]$manifest, [string]$remoteDirectory, [string]$target) {
    $state = Get-DirectoryState $target
    if ($state -eq "used") {
        Write-Step "skip" $label "$target already has files"
        return
    }

    if ($state -eq "file") {
        Write-Step "fail" $label "$target exists and is not a directory"
        return
    }

    $manifestPath = Join-Path $temporaryDirectory $manifest
    $problem = Get-RemoteFile "$scriptsBase/$manifest" $manifestPath
    if ($problem) {
        Write-Step "fail" $label "Could not download ${manifest}: $problem"
        return
    }

    $files = @()
    foreach ($line in (Get-Content -LiteralPath $manifestPath)) {
        $name = $line.Trim()
        if ($name.Length -eq 0) {
            continue
        }

        if (-not (Test-CatalogFileName $name)) {
            Write-Step "fail" $label "$manifest has an invalid file name: $name"
            return
        }

        $files += $name
    }

    if ($files.Count -eq 0) {
        Write-Step "fail" $label "$manifest lists no files"
        return
    }

    $stage = Join-Path $temporaryDirectory "stage-$label"
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    if (-not $Styled) {
        Write-Host "Downloading $label files ($($files.Count))..."
    }

    $index = 0
    foreach ($name in $files) {
        Write-CountBar $label $index $files.Count
        $stagedPath = Join-Path $stage $name
        $problem = Get-RemoteFile "$defaultsBase/$remoteDirectory/$name" $stagedPath
        if ($problem) {
            Clear-CurrentLine
            Write-Step "fail" $label "Could not download ${name}: $problem"
            return
        }

        if ((Get-Item -LiteralPath $stagedPath).Length -eq 0) {
            Clear-CurrentLine
            Write-Step "fail" $label "$name downloaded empty"
            return
        }

        $index++
    }

    Clear-CurrentLine

    try {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        foreach ($name in $files) {
            Copy-Item -LiteralPath (Join-Path $stage $name) -Destination $target -Force
        }
    }
    catch {
        # The directory was empty before this step, so removing only what the
        # manifest names restores it.
        foreach ($name in $files) {
            Remove-Item -LiteralPath (Join-Path $target $name) -Force -ErrorAction SilentlyContinue
        }

        Remove-EmptyDirectory $target
        Write-Step "fail" $label "Could not write files to ${target}: $($_.Exception.Message)"
        return
    }

    Write-Step "ok" $label "Installed $($files.Count) files to $target"
}

# Installs the latest web plugin into plugins/web when plugins/ is empty. The
# release archive is built per platform with the same names as the core
# archives, so the detected asset applies here too.
function Install-Plugin {
    $pluginsDirectory = Join-Path $crystalHome "plugins"
    $pluginTarget = Join-Path $pluginsDirectory $pluginDirectoryName

    $state = Get-DirectoryState $pluginsDirectory
    if ($state -eq "used") {
        Write-Step "skip" "plugins" "$pluginsDirectory already has entries"
        return
    }

    if ($state -eq "file") {
        Write-Step "fail" "plugins" "$pluginsDirectory exists and is not a directory"
        return
    }

    $pluginArchiveName = "CrystalCode.Web-$asset.zip"
    $pluginArchivePath = Join-Path $temporaryDirectory $pluginArchiveName
    $pluginUrl = "https://github.com/$pluginRepository/releases/latest/download/$pluginArchiveName"

    $downloaded = $false
    if ($Styled) {
        Write-Host ("  " + $Muted + "[....]" + $Reset + " plugins   Downloading $pluginArchiveName")
        $downloaded = Receive-CrystalArchive $pluginUrl $pluginArchivePath $pluginArchiveName
        Clear-Lines 2
    }
    else {
        Write-Host "Downloading $pluginArchiveName..."
        $downloaded = -not (Get-RemoteFile $pluginUrl $pluginArchivePath)
    }

    if (-not $downloaded) {
        Write-Step "fail" "plugins" "Could not download $pluginArchiveName from the latest release"
        return
    }

    $pluginExtraction = Join-Path $temporaryDirectory "plugin"
    try {
        Expand-Archive -LiteralPath $pluginArchivePath -DestinationPath $pluginExtraction -Force
    }
    catch {
        Write-Step "fail" "plugins" "Could not extract ${pluginArchiveName}: $($_.Exception.Message)"
        return
    }

    $pluginManifest = Get-ChildItem -LiteralPath $pluginExtraction -Filter "plugin.json" -File -Recurse |
        Select-Object -First 1
    if ($null -eq $pluginManifest) {
        Write-Step "fail" "plugins" "$pluginArchiveName does not contain plugin.json"
        return
    }

    $pluginSource = $pluginManifest.DirectoryName
    if (-not (Test-Path -LiteralPath (Join-Path $pluginSource "CrystalCode.Web.dll") -PathType Leaf)) {
        Write-Step "fail" "plugins" "$pluginArchiveName does not contain CrystalCode.Web.dll"
        return
    }

    try {
        # The manifest ships enabled. Make that true even if a release changes it.
        $manifestText = [System.IO.File]::ReadAllText($pluginManifest.FullName)
        $enabledText = [regex]::Replace($manifestText, '("enabled"\s*:\s*)false', '${1}true')
        if ($enabledText -ne $manifestText) {
            [System.IO.File]::WriteAllText($pluginManifest.FullName, $enabledText, [System.Text.UTF8Encoding]::new($false))
        }

        New-Item -ItemType Directory -Path $pluginTarget -Force | Out-Null
        Copy-Item -Path (Join-Path $pluginSource "*") -Destination $pluginTarget -Recurse -Force
    }
    catch {
        # plugins/ was empty before this step, so the plugin directory is ours.
        Remove-Item -LiteralPath $pluginTarget -Recurse -Force -ErrorAction SilentlyContinue
        Remove-EmptyDirectory $pluginsDirectory
        Write-Step "fail" "plugins" "Could not write files to ${pluginTarget}: $($_.Exception.Message)"
        return
    }

    Write-Step "ok" "plugins" "Installed $pluginDirectoryName to $pluginTarget"

    # Discovery is on by default. Only an explicit false in config.json turns it off.
    $configPath = Join-Path $crystalHome "config.json"
    if ((Test-Path -LiteralPath $configPath -PathType Leaf) -and
        ([System.IO.File]::ReadAllText($configPath) -match '"plugins"\s*:\s*false')) {
        Write-Host ("  " + $Muted + "[note]" + $Reset + " plugins   Plugin discovery is off in config.json. Run /plugins on in Crystal Code.")
    }
}

function Install-Extras {
    Write-Host ""
    Write-Host ($Muted + "Setting up plugins, providers, and themes..." + $Reset)
    Write-Host ""

    # A step reports its own failures. This catches only what it did not foresee.
    try { Install-Plugin } catch { Write-Step "fail" "plugins" $_.Exception.Message }
    try { Install-Catalog "providers" "providers.txt" "providers" (Join-Path $crystalHome "providers") } catch { Write-Step "fail" "providers" $_.Exception.Message }
    try { Install-Catalog "themes" "themes.txt" "themes" (Join-Path $crystalHome "themes") } catch { Write-Step "fail" "themes" $_.Exception.Message }

    if ($ExtrasFailed -gt 0) {
        Write-Host ""
        [Console]::Error.WriteLine($FailColor + "Crystal Code is installed, but $ExtrasFailed extra step(s) did not finish." + $Reset)
        [Console]::Error.WriteLine("Run this installer again after fixing the cause. Finished steps are skipped.")
    }
}

if (-not [Console]::IsOutputRedirected -and
    -not [Console]::IsErrorRedirected -and
    [string]::IsNullOrEmpty($env:NO_COLOR) -and
    $env:TERM -ne "dumb") {
    $Styled = $true
    $Muted = "$Esc[38;5;242m"
    $Reset = "$Esc[0m"
    if ($env:COLORTERM -eq "truecolor" -or $env:COLORTERM -eq "24bit") {
        $Accent = "$Esc[38;2;176;196;222m"
        $FailColor = "$Esc[38;2;205;92;92m"
    }
    else {
        $Accent = "$Esc[38;5;152m"
        $FailColor = "$Esc[38;5;167m"
    }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Fail "This installer is for Windows."
}

$architecture = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITEW6432")
if ([string]::IsNullOrWhiteSpace($architecture)) {
    $architecture = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE")
}

$asset = switch ($architecture) {
    "AMD64" { "windows-x64" }
    "ARM64" { "windows-arm64" }
    default { Fail "Unsupported Windows architecture: $architecture" }
}

$archiveName = "CrystalCode-$asset.zip"
$downloadUrl = "https://github.com/$repository/releases/latest/download/$archiveName"
$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("CrystalCode-" + [Guid]::NewGuid().ToString("N"))
$archivePath = Join-Path $temporaryDirectory $archiveName
$extractionDirectory = Join-Path $temporaryDirectory "extracted"

New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if ($Styled) {
        Enable-VirtualTerminal
        Write-Host ($Muted + "Installing Crystal Code..." + $Reset)
        Write-Host ""
        if (-not (Receive-CrystalArchive $downloadUrl $archivePath $archiveName)) {
            Fail "Could not download $archiveName from the latest release."
        }
    }
    else {
        Write-Host "Downloading $archiveName..."
        $webClient = [System.Net.WebClient]::new()
        try {
            $webClient.DownloadFile($downloadUrl, $archivePath)
        }
        finally {
            $webClient.Dispose()
        }
    }

    if (-not $Styled) {
        Write-Host "Extracting $archiveName..."
    }

    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractionDirectory -Force
    $publishedBinary = Get-ChildItem -LiteralPath $extractionDirectory -Filter $binaryName -File -Recurse |
        Select-Object -First 1

    if ($null -eq $publishedBinary) {
        Fail "The archive does not contain $binaryName."
    }

    $publishedDirectory = $publishedBinary.DirectoryName
    if (-not $Styled) {
        Write-Host "Installing Crystal Code files..."
    }

    New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
    Copy-Item -Path (Join-Path $publishedDirectory "*") -Destination $installDirectory -Recurse -Force

    if ($Styled) {
        $addedToPath = Add-UserPath $installDirectory
        Install-Extras
        Write-Card -addedToPath $addedToPath -archiveName $archiveName -installDirectory $installDirectory
    }
    else {
        Write-Host "Installed $archiveName to $installDirectory"
        Write-Host "Configuring the user PATH..."
        Add-UserPath $installDirectory | Out-Null
        Write-Host "Open a new terminal to use CrystalCode from any directory."
        Write-Host "Start Crystal Code with: CrystalCode"
        Install-Extras
    }
}
finally {
    if ($CursorHidden) {
        [Console]::Write("`n")
    }

    Restore-Cursor
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

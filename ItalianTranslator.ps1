param(
    [string]$GameRoot = '',
    [string]$Model = 'qwen3:14b',
    [string]$OllamaUrl = 'http://127.0.0.1:11434/api/generate',
    [switch]$EventStream,
    [ValidateSet('Gui', 'Analyze', 'Sync', 'Review', 'Install', 'Uninstall', 'Validate')]
    [string]$Action = 'Gui'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function ConvertTo-EncodedCommand {
    param([string]$Command)

    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
}

function New-ScriptInvocationCommand {
    param(
        [string]$ActionName,
        [string]$Root,
        [string]$ModelName,
        [string]$Url,
        [switch]$WithEventStream
    )

    $escape = { param([string]$Value) "'" + $Value.Replace("'", "''") + "'" }
    $parts = @(
        "& $(& $escape $PSCommandPath)"
        "-Action $(& $escape $ActionName)"
        "-GameRoot $(& $escape $Root)"
        "-Model $(& $escape $ModelName)"
        "-OllamaUrl $(& $escape $Url)"
    )
    if ($WithEventStream) {
        $parts += '-EventStream'
    }
    return $parts -join ' '
}

if ($Action -eq 'Gui' -and [System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $command = New-ScriptInvocationCommand -ActionName 'Gui' -Root $GameRoot -ModelName $Model -Url $OllamaUrl
    $arguments = "-NoProfile -ExecutionPolicy Bypass -STA -EncodedCommand $(ConvertTo-EncodedCommand $command)"
    Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $PSScriptRoot
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Model = $Model
$script:OllamaUrl = $OllamaUrl
$script:Ui = $null
$script:StatusPrefix = '@@ITALIAN_TRANSLATOR_STATUS@@'
$script:EmitStatusEvents = [bool]$EventStream
$script:BatchMaxItems = 32
$script:BatchMaxCharacters = 10000
$script:CheckpointEveryBatches = 1
$script:UiMutex = $null

function Get-ToolMutexName {
    param([string]$Purpose)

    $normalizedPath = [IO.Path]::GetFullPath($PSScriptRoot).ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalizedPath))
    } finally {
        $sha.Dispose()
    }
    $suffix = ([BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 16)
    return "Local\ItalianTranslator_${Purpose}_$suffix"
}

function Enter-ToolMutex {
    param([string]$Purpose)

    $mutex = [Threading.Mutex]::new($false, (Get-ToolMutexName $Purpose))
    try {
        $acquired = $mutex.WaitOne(0)
    } catch [Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
        $mutex.Dispose()
        throw "Un'altra operazione '$Purpose' è già in esecuzione per questa cartella."
    }
    return $mutex
}

function Get-PackagePaths {
    param([string]$Root)

    return [pscustomobject]@{
        ToolRoot            = $PSScriptRoot
        GameRoot            = $Root
        ResourcesAssets     = Join-Path $Root 'Hunters Moon_Data\resources.assets'
        GameManaged         = Join-Path $Root 'Hunters Moon_Data\Managed'
        GameLocales         = Join-Path $Root 'Hunters Moon_Data\StreamingAssets\Locales'
        GameLocaleDll       = Join-Path $Root 'Hunters Moon_Data\Managed\Locale.dll'
        GameLocaleJson      = Join-Path $Root 'Hunters Moon_Data\StreamingAssets\Locales\Italian_translated.json'
        GameLegacyPatchDll  = Join-Path $Root 'Hunters Moon_Data\Managed\ItalianPatch.dll'
        SourceFile          = Join-Path $PSScriptRoot 'source\English.json'
        WorkFile            = Join-Path $PSScriptRoot 'work\Italian.json'
        TranslatedFile      = Join-Path $PSScriptRoot 'work\Italian_translated.json'
        ReleaseDll          = Join-Path $PSScriptRoot 'release\Hunters Moon_Data\Managed\Locale.dll'
        ReleaseJson         = Join-Path $PSScriptRoot 'release\Hunters Moon_Data\StreamingAssets\Locales\Italian_translated.json'
        BackupRoot          = Join-Path $PSScriptRoot 'backup'
        HistoryRoot         = Join-Path $PSScriptRoot 'backup\history'
        InstallBackupRoot   = Join-Path $Root '.italian-translation-backup'
        BackupDll           = Join-Path $Root '.italian-translation-backup\Locale.original.dll'
        BackupJson          = Join-Path $Root '.italian-translation-backup\Italian_translated.original.json'
        ConfigFile          = Join-Path $PSScriptRoot 'work\settings.json'
    }
}

function Test-GameInstallation {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }

    return (Test-Path -LiteralPath (Join-Path $Root 'Hunters Moon.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Root 'Hunters Moon_Data\resources.assets') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Root 'Hunters Moon_Data\Managed\Assembly-CSharp.dll') -PathType Leaf)
}

function Save-GameInstallation {
    param([string]$Root)

    if (-not (Test-GameInstallation $Root)) {
        return
    }

    try {
        $configFile = Join-Path $PSScriptRoot 'work\settings.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $configFile) | Out-Null
        $config = [ordered]@{ GameRoot = [IO.Path]::GetFullPath($Root) }
        [IO.File]::WriteAllText($configFile, ($config | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    } catch {
        # The selected path still works when the portable tool is read-only.
    }
}

function Find-GameInstallation {
    param([string]$Preferred)

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
        $candidates.Add($Preferred)
    }

    $configFile = Join-Path $PSScriptRoot 'work\settings.json'
    if (Test-Path -LiteralPath $configFile) {
        try {
            $saved = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
            if ($saved.GameRoot) {
                $candidates.Add([string]$saved.GameRoot)
            }
        } catch {}
    }

    $candidates.Add((Split-Path -Parent $PSScriptRoot))
    $candidates.Add((Get-Location).Path)

    $registryRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($registryRoot in $registryRoots) {
        try {
            foreach ($entry in @(Get-ItemProperty -Path $registryRoot -ErrorAction SilentlyContinue)) {
                if ($entry.DisplayName -like "*Hunter's Moon*" -and $entry.InstallLocation) {
                    $candidates.Add([string]$entry.InstallLocation)
                }
            }
        } catch {}
    }

    foreach ($gogKey in @(
        'HKLM:\Software\GOG.com\Games\1636747385',
        'HKLM:\Software\WOW6432Node\GOG.com\Games\1636747385'
    )) {
        try {
            $entry = Get-ItemProperty -LiteralPath $gogKey -ErrorAction Stop
            foreach ($property in @('PATH', 'Path', 'InstallLocation')) {
                if ($entry.$property) {
                    $candidates.Add([string]$entry.$property)
                }
            }
        } catch {}
    }

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        try {
            $fullPath = [IO.Path]::GetFullPath($candidate.Trim().Trim('"'))
        } catch {
            continue
        }
        if ($seen.Add($fullPath) -and (Test-GameInstallation $fullPath)) {
            return $fullPath
        }
    }

    return ''
}

function Assert-GameInstallation {
    param([string]$Root)

    if (-not (Test-GameInstallation $Root)) {
        throw "Cartella del gioco non valida: '$Root'. Seleziona la cartella che contiene 'Hunters Moon.exe'."
    }
}

function Ensure-PackageFolders {
    param($Paths)

    New-Item -ItemType Directory -Force -Path `
        (Split-Path -Parent $Paths.WorkFile), `
        (Split-Path -Parent $Paths.TranslatedFile), `
        (Split-Path -Parent $Paths.ReleaseDll), `
        (Split-Path -Parent $Paths.ReleaseJson), `
        $Paths.BackupRoot, `
        $Paths.HistoryRoot | Out-Null
}

function Read-LocaleEntries {
    param([string]$Path)

    $entries = New-Object System.Collections.Specialized.OrderedDictionary
    if (-not (Test-Path -LiteralPath $Path)) {
        return $entries
    }

    $pattern = '^\s*"(?<key>(?:\\.|[^"])*)"\s*:\s*"(?<value>(?:\\.|[^"])*)"\s*,?\s*$'
    $reader = [System.IO.StreamReader]::new($Path, [System.Text.UTF8Encoding]::new($false, $false), $true)
    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($line -match $pattern) {
                $key = ('"' + $Matches.key + '"' | ConvertFrom-Json)
                $value = ('"' + $Matches.value + '"' | ConvertFrom-Json)
                if (-not $entries.Contains($key)) {
                    $entries.Add($key, $value)
                }
            }
        }
    } finally {
        $reader.Dispose()
    }

    return $entries
}

function Write-LocaleEntries {
    param(
        [string]$Path,
        $Entries
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('{')

    $index = 0
    foreach ($key in $Entries.Keys) {
        $keyJson = $key | ConvertTo-Json -Compress -Depth 4
        $valueJson = $Entries[$key] | ConvertTo-Json -Compress -Depth 4
        $suffix = if ($index -lt ($Entries.Count - 1)) { ',' } else { '' }
        $lines.Add(("`t{0}: {1}{2}" -f $keyJson, $valueJson, $suffix))
        $index++
    }

    $lines.Add('}')
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $tempPath = Join-Path $directory ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($Path)), ([guid]::NewGuid().ToString('N')))
    try {
        [System.IO.File]::WriteAllText($tempPath, ($lines -join [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Copy-OrderedDictionary {
    param($Source)

    $copy = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($key in $Source.Keys) {
        $copy[$key] = $Source[$key]
    }
    return $copy
}

function Initialize-AssetExtractor {
    if ('ItalianTranslator.AssetBlockReader' -as [type]) {
        return
    }

    $source = @'
using System;
using System.IO;
using System.Text;

namespace ItalianTranslator
{
    public static class AssetBlockReader
    {
        private const int BufferSize = 1024 * 1024;
        private const int MaxBlockSize = 64 * 1024 * 1024;

        public static long FindAscii(string path, string pattern, long startAt)
        {
            byte[] needle = Encoding.ASCII.GetBytes(pattern);
            int[] prefix = BuildPrefix(needle);
            int matched = 0;
            long position = startAt;
            byte[] buffer = new byte[BufferSize];

            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                stream.Seek(startAt, SeekOrigin.Begin);
                int count;
                while ((count = stream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    for (int i = 0; i < count; i++, position++)
                    {
                        while (matched > 0 && buffer[i] != needle[matched])
                            matched = prefix[matched - 1];
                        if (buffer[i] == needle[matched])
                            matched++;
                        if (matched == needle.Length)
                            return position - needle.Length + 1;
                    }
                }
            }
            return -1;
        }

        public static string ReadTable(string path, long markerPosition, string header)
        {
            long headerPosition = FindAscii(path, header, markerPosition);
            if (headerPosition < 0)
                throw new InvalidDataException("Header della tabella non trovato.");

            long start = headerPosition + Encoding.ASCII.GetByteCount(header);
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                stream.Seek(start, SeekOrigin.Begin);
                int current;
                while ((current = stream.ReadByte()) >= 0 && (current == 10 || current == 13)) { }
                if (current >= 0)
                    stream.Seek(-1, SeekOrigin.Current);

                using (MemoryStream output = new MemoryStream())
                {
                    byte[] buffer = new byte[BufferSize];
                    while (output.Length < MaxBlockSize)
                    {
                        int count = stream.Read(buffer, 0, buffer.Length);
                        if (count <= 0)
                            break;
                        int end = Array.IndexOf(buffer, (byte)0, 0, count);
                        if (end >= 0)
                        {
                            output.Write(buffer, 0, end);
                            break;
                        }
                        output.Write(buffer, 0, count);
                    }
                    return Encoding.UTF8.GetString(output.ToArray());
                }
            }
        }

        public static string ReadTextAsset(string path, string assetName)
        {
            byte[] nameBytes = Encoding.UTF8.GetBytes(assetName);
            long searchAt = 0;
            while (true)
            {
                long namePosition = FindAscii(path, assetName, searchAt);
                if (namePosition < 0)
                    break;
                searchAt = namePosition + 1;
                if (namePosition < 4)
                    continue;

                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (BinaryReader reader = new BinaryReader(stream, Encoding.UTF8, true))
                {
                    stream.Seek(namePosition - 4, SeekOrigin.Begin);
                    if (reader.ReadInt32() != nameBytes.Length)
                        continue;

                    long lengthPosition = (namePosition + nameBytes.Length + 3L) & ~3L;
                    stream.Seek(lengthPosition, SeekOrigin.Begin);
                    int dataLength = reader.ReadInt32();
                    if (dataLength <= 0 || dataLength > MaxBlockSize || stream.Position + dataLength > stream.Length)
                        continue;

                    byte[] data = reader.ReadBytes(dataLength);
                    if (data.Length == dataLength && data[0] == (byte)'{')
                        return Encoding.UTF8.GetString(data);
                }
            }

            throw new InvalidDataException("TextAsset non trovato: " + assetName);
        }

        private static int[] BuildPrefix(byte[] needle)
        {
            int[] prefix = new int[needle.Length];
            int length = 0;
            for (int i = 1; i < needle.Length; i++)
            {
                while (length > 0 && needle[i] != needle[length])
                    length = prefix[length - 1];
                if (needle[i] == needle[length])
                    length++;
                prefix[i] = length;
            }
            return prefix;
        }
    }
}
'@

    Add-Type -TypeDefinition $source -Language CSharp
}

function Protect-Text {
    param([string]$Text)

    $mapping = New-Object System.Collections.Specialized.OrderedDictionary
    $pattern = '(\r\n|\n|\t|\\r\\n|\\n|\\t|\[[A-Za-z0-9_]+\]|<[^>]+>|\{[^}]+\})'

    $protected = [System.Text.RegularExpressions.Regex]::Replace($Text, $pattern, {
        param($match)
        $token = "__TOKEN_$($mapping.Count)__"
        $mapping[$token] = $match.Value
        return $token
    })

    return [pscustomobject]@{
        Text = $protected
        Map  = $mapping
    }
}

function Get-ProtectedTokens {
    param([string]$Text)

    return @([regex]::Matches($Text, '(\r\n|\n|\t|\\r\\n|\\n|\\t|\[[A-Za-z0-9_]+\]|<[^>]+>|\{[^}]+\})') | ForEach-Object Value)
}

function Test-TranslationStructure {
    param(
        [string]$SourceText,
        [string]$TranslatedText
    )

    if ($TranslatedText -match '__TOKEN_\d+__|<think>|```|�') {
        return $false
    }

    $sourceTokens = @(Get-ProtectedTokens $SourceText)
    $translatedTokens = @(Get-ProtectedTokens $TranslatedText)
    return (($sourceTokens -join "`n") -ceq ($translatedTokens -join "`n"))
}

function Restore-Text {
    param(
        [string]$Text,
        $Map
    )

    foreach ($token in $Map.Keys) {
        $Text = $Text.Replace($token, [string]$Map[$token])
    }

    return $Text
}

function Format-PreviewText {
    param(
        [string]$Text,
        [int]$MaxLength = 120
    )

    $flat = $Text -replace '\r?\n', ' '
    if ($flat.Length -le $MaxLength) {
        return $flat
    }

    return $flat.Substring(0, $MaxLength - 1) + '…'
}

function Format-ExceptionDetails {
    param([object]$ErrorRecord)

    if ($null -eq $ErrorRecord) {
        return 'Errore sconosciuto.'
    }

    $exception = $ErrorRecord.Exception
    if ($exception) {
        $details = $exception.ToString()
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = $exception.Message
        }
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = $ErrorRecord.ToString()
        }
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = $exception.GetType().FullName
        }
        return $details
    }

    $text = $ErrorRecord.ToString()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'Errore sconosciuto.'
    }
    return $text
}

function Write-Log {
    param([string]$Message)

    if ($script:UiState) {
        $script:UiState.Queue.Enqueue($Message)
    } else {
        Write-Output $Message
    }
}

function Set-UiStatus {
    param(
        [string]$Message,
        [int]$Value = -1,
        [int]$Maximum = -1,
        [switch]$Marquee
    )

    if ($script:UiState) {
        $script:UiState.Status = $Message
        $script:UiState.Marquee = [bool]$Marquee
        if ($Maximum -gt 0) {
            $script:UiState.Maximum = $Maximum
        }
        if ($Value -ge 0) {
            $script:UiState.Value = $Value
        }
    } elseif ($script:EmitStatusEvents) {
        $event = @{
            message = $Message
            value = $Value
            maximum = $Maximum
            marquee = [bool]$Marquee
        } | ConvertTo-Json -Compress
        Write-Output ($script:StatusPrefix + $event)
    }
}

function Flush-UiState {
    if (-not $script:Ui -or -not $script:UiState) {
        return
    }

    $logLines = New-Object System.Collections.Generic.List[string]
    $msg = $null
    while ($script:UiState.Queue.TryDequeue([ref]$msg)) {
        $logLines.Add($msg)
    }
    if ($logLines.Count -gt 0) {
        $script:Ui.Log.AppendText(($logLines -join [Environment]::NewLine) + [Environment]::NewLine)
        $script:Ui.Log.SelectionStart = $script:Ui.Log.TextLength
        $script:Ui.Log.ScrollToCaret()
    }

    if ($script:Ui.Status.Text -ne $script:UiState.Status) {
        $script:Ui.Status.Text = $script:UiState.Status
    }
    if ($script:UiState.Marquee) {
        if ($script:Ui.Progress.Style -ne [System.Windows.Forms.ProgressBarStyle]::Marquee) {
            $script:Ui.Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        }
    } else {
        if ($script:Ui.Progress.Style -ne [System.Windows.Forms.ProgressBarStyle]::Continuous) {
            $script:Ui.Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        }
        if ($script:UiState.Maximum -gt 0) {
            $script:Ui.Progress.Maximum = [Math]::Max(1, [int]$script:UiState.Maximum)
        }
        if ($script:UiState.Value -ge 0) {
            $script:Ui.Progress.Value = [Math]::Min([int]$script:UiState.Value, $script:Ui.Progress.Maximum)
        }
    }
}

function Read-NewLogText {
    param(
        [string]$Path,
        [ref]$Offset,
        [System.Text.Decoder]$Decoder
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($stream.Length -le [long]$Offset.Value) {
                return ''
            }

            [void]$stream.Seek([long]$Offset.Value, [System.IO.SeekOrigin]::Begin)
            $remaining = [int]($stream.Length - [long]$Offset.Value)
            $bytes = New-Object byte[] $remaining
            $read = $stream.Read($bytes, 0, $remaining)
            $Offset.Value = [long]$Offset.Value + $read
            if ($read -le 0) {
                return ''
            }

            $chars = New-Object char[] $read
            $charCount = $Decoder.GetChars($bytes, 0, $read, $chars, 0, $false)
            return [string]::new($chars, 0, $charCount)
        } finally {
            $stream.Dispose()
        }
    } catch [System.IO.IOException] {
        return ''
    }
}

function Add-OperationLines {
    param(
        [string]$Text,
        [ref]$Remainder,
        [System.Collections.Generic.List[string]]$LogLines,
        [switch]$ErrorOutput
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return
    }

    $parts = [regex]::Split(($Remainder.Value + $Text), "\r?\n")
    $Remainder.Value = $parts[$parts.Count - 1]
    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        $line = $parts[$i]
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if (-not $ErrorOutput -and $line.StartsWith($script:StatusPrefix, [StringComparison]::Ordinal)) {
            try {
                $statusEvent = $line.Substring($script:StatusPrefix.Length) | ConvertFrom-Json
                Set-UiStatus -Message ([string]$statusEvent.message) -Value ([int]$statusEvent.value) -Maximum ([int]$statusEvent.maximum) -Marquee:([bool]$statusEvent.marquee)
            } catch {
                $LogLines.Add($line)
            }
            continue
        }

        $LogLines.Add($(if ($ErrorOutput) { 'ERR: ' + $line } else { $line }))
    }
}

function Update-UiOperation {
    if (-not $script:UiState -or -not $script:UiState.Operation) {
        return
    }

    $operation = $script:UiState.Operation
    $logLines = New-Object System.Collections.Generic.List[string]

    $outputOffset = [long]$operation.OutputOffset
    $outputText = Read-NewLogText -Path $operation.OutputPath -Offset ([ref]$outputOffset) -Decoder $operation.OutputDecoder
    $operation.OutputOffset = $outputOffset
    $outputRemainder = [string]$operation.OutputRemainder
    Add-OperationLines -Text $outputText -Remainder ([ref]$outputRemainder) -LogLines $logLines
    $operation.OutputRemainder = $outputRemainder

    $errorOffset = [long]$operation.ErrorOffset
    $errorText = Read-NewLogText -Path $operation.ErrorPath -Offset ([ref]$errorOffset) -Decoder $operation.ErrorDecoder
    $operation.ErrorOffset = $errorOffset
    $errorRemainder = [string]$operation.ErrorRemainder
    Add-OperationLines -Text $errorText -Remainder ([ref]$errorRemainder) -LogLines $logLines -ErrorOutput
    $operation.ErrorRemainder = $errorRemainder

    if ($logLines.Count -gt 0) {
        $script:Ui.Log.AppendText(($logLines -join [Environment]::NewLine) + [Environment]::NewLine)
        $script:Ui.Log.SelectionStart = $script:Ui.Log.TextLength
        $script:Ui.Log.ScrollToCaret()
    }

    if (-not $operation.Process.HasExited) {
        return
    }

    foreach ($remainder in @($operation.OutputRemainder, $operation.ErrorRemainder)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$remainder)) {
            $script:Ui.Log.AppendText(([string]$remainder) + [Environment]::NewLine)
        }
    }

    try { $operation.Process.WaitForExit() } catch {}
    $operation.Process.Refresh()
    $exitCode = $operation.Process.ExitCode
    if ($null -eq $exitCode -or [string]::IsNullOrWhiteSpace([string]$exitCode)) {
        $exitCode = 1
    }
    $script:UiState.Operation = $null
    $script:UiState.Busy = $false
    $script:Ui.Form.UseWaitCursor = $false
    foreach ($button in $script:Ui.Buttons) {
        $button.Enabled = $true
    }
    if ($script:Ui.CancelButton) {
        $script:Ui.CancelButton.Enabled = $false
    }

    if ($operation.Cancelled) {
        Set-UiStatus -Message 'Operazione annullata' -Value 0 -Maximum 1
    } elseif ($exitCode -eq 0) {
        Set-UiStatus -Message 'Operazione completata' -Value 1 -Maximum 1
    } else {
        Write-Log "Operazione terminata con codice $exitCode."
        Set-UiStatus -Message "Errore durante l'operazione" -Value 0 -Maximum 1
    }
    Flush-UiState

    try { $operation.Process.Dispose() } catch {}
    try {
        if (Test-Path -LiteralPath $operation.TempDir) {
            Remove-Item -LiteralPath $operation.TempDir -Recurse -Force
        }
    } catch {}
}

function Get-ResourceRows {
    param($Paths)

    if (-not (Test-Path -LiteralPath $Paths.ResourcesAssets)) {
        throw "resources.assets non trovato: $($Paths.ResourcesAssets)"
    }
    Initialize-AssetExtractor
    Add-Type -AssemblyName Microsoft.VisualBasic

    $header = 'KEY,EN,CHs,CHt,JP,KO,TH,DE,FR,SP,RU,PL,UA,TU,BR'
    $customMarker = 'Custom Translations - All'
    $standardMarker = 'Translations - All'
    $customPosition = [ItalianTranslator.AssetBlockReader]::FindAscii($Paths.ResourcesAssets, $customMarker, 0)
    $standardSearchStart = if ($customPosition -ge 0) { $customPosition + $customMarker.Length } else { 0 }
    $standardPosition = [ItalianTranslator.AssetBlockReader]::FindAscii($Paths.ResourcesAssets, $standardMarker, $standardSearchStart)

    $rows = New-Object System.Collections.Specialized.OrderedDictionary
    $tables = @(
        [pscustomobject]@{ Namespace = 'custom'; Position = $customPosition },
        [pscustomobject]@{ Namespace = 'main'; Position = $standardPosition }
    )
    foreach ($table in $tables) {
        $markerPosition = $table.Position
        if ($markerPosition -lt 0) {
            continue
        }

        $block = [ItalianTranslator.AssetBlockReader]::ReadTable($Paths.ResourcesAssets, $markerPosition, $header)
        $textReader = [System.IO.StringReader]::new($block)
        $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($textReader)
        try {
            $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
            $parser.SetDelimiters(',')
            $parser.HasFieldsEnclosedInQuotes = $true
            $parser.TrimWhiteSpace = $false

            while (-not $parser.EndOfData) {
                try {
                    $fields = $parser.ReadFields()
                } catch [Microsoft.VisualBasic.FileIO.MalformedLineException] {
                    continue
                }
                if ($null -eq $fields -or $fields.Count -lt 2) {
                    continue
                }

                $key = ([string]$fields[0]).Trim()
                $english = [string]$fields[1]
                if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($english)) {
                    continue
                }

                # Main and custom CSV files deliberately reuse keys. Card titles
                # live in main while descriptions live in custom, so flattening
                # them makes descriptions overwrite titles at runtime.
                $namespacedKey = '{0}::{1}' -f $table.Namespace, $key
                if (-not $rows.Contains($namespacedKey)) {
                    $rows[$namespacedKey] = $english
                }
            }
        } finally {
            $parser.Dispose()
            $textReader.Dispose()
        }
    }

    # A third localization source is stored as the English TextAsset. It
    # contains cutscenes and legacy UI strings that are absent from both CSVs.
    $embeddedEnglish = [ItalianTranslator.AssetBlockReader]::ReadTextAsset($Paths.ResourcesAssets, 'English')
    $localePattern = '^\s*"(?<key>(?:\\.|[^"])*)"\s*:\s*"(?<value>(?:\\.|[^"])*)"\s*,?\s*$'
    $localeReader = [IO.StringReader]::new($embeddedEnglish)
    try {
        while (($line = $localeReader.ReadLine()) -ne $null) {
            if ($line -notmatch $localePattern) {
                continue
            }
            $key = ('"' + $Matches.key + '"' | ConvertFrom-Json)
            $english = ('"' + $Matches.value + '"' | ConvertFrom-Json)
            if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($english)) {
                continue
            }
            $namespacedKey = 'main::{0}' -f $key
            if (-not $rows.Contains($namespacedKey)) {
                $rows[$namespacedKey] = $english
            }
        }
    } finally {
        $localeReader.Dispose()
    }

    return $rows
}

function Get-LegacyLocaleKey {
    param([string]$NamespacedKey)

    $separator = $NamespacedKey.IndexOf('::', [StringComparison]::Ordinal)
    if ($separator -lt 0) {
        return $NamespacedKey
    }
    return $NamespacedKey.Substring($separator + 2)
}

function Get-LegacyTranslationEntries {
    param($Paths)

    $best = New-Object System.Collections.Specialized.OrderedDictionary
    $bestPath = ''
    $candidates = @()
    if (Test-Path -LiteralPath $Paths.HistoryRoot) {
        $candidates += @(Get-ChildItem -LiteralPath $Paths.HistoryRoot -Filter 'Italian_translated_*.json' -File -ErrorAction SilentlyContinue)
    }
    foreach ($candidate in $candidates) {
        $entries = Read-LocaleEntries $candidate.FullName
        if ($entries.Count -le $best.Count) {
            continue
        }
        $hasNamespaces = $false
        foreach ($key in $entries.Keys) {
            if ([string]$key -match '^(main|custom)::') {
                $hasNamespaces = $true
                break
            }
        }
        if (-not $hasNamespaces) {
            $best = $entries
            $bestPath = $candidate.FullName
        }
    }

    return [pscustomobject]@{ Entries = $best; Path = $bestPath }
}

function Convert-ToNamespacedTranslations {
    param(
        $Source,
        $Translated,
        $Resources,
        $LegacyTranslated
    )

    $result = New-Object System.Collections.Specialized.OrderedDictionary
    $migrated = 0
    $legacyMigrated = 0
    $baseKeyCounts = @{}
    foreach ($resourceKey in $Resources.Keys) {
        $baseKey = Get-LegacyLocaleKey $resourceKey
        if (-not $baseKeyCounts.ContainsKey($baseKey)) {
            $baseKeyCounts[$baseKey] = 0
        }
        $baseKeyCounts[$baseKey]++
    }
    foreach ($key in $Resources.Keys) {
        if ($Translated.Contains($key)) {
            $result[$key] = [string]$Translated[$key]
            continue
        }

        $legacyKey = Get-LegacyLocaleKey $key
        if ($Translated.Contains($legacyKey) -and $Source.Contains($legacyKey) -and
            [string]$Source[$legacyKey] -ceq [string]$Resources[$key]) {
            $result[$key] = [string]$Translated[$legacyKey]
            $migrated++
            continue
        }

        # Flat backups can be mapped safely only when that base key occurs in
        # one table. Duplicate card keys must never cross title/description.
        if ($LegacyTranslated -and $LegacyTranslated.Contains($legacyKey) -and $baseKeyCounts[$legacyKey] -eq 1) {
            $result[$key] = [string]$LegacyTranslated[$legacyKey]
            $legacyMigrated++
        }
    }

    return [pscustomobject]@{
        Entries = $result
        Count = $migrated
        LegacyCount = $legacyMigrated
    }
}

function Get-TranslationAnalysis {
    param($Paths)

    $source = Read-LocaleEntries $Paths.SourceFile
    $translated = Read-LocaleEntries $Paths.TranslatedFile
    $resources = Get-ResourceRows -Paths $Paths
    $effectiveSource = Copy-OrderedDictionary $resources
    $legacy = Get-LegacyTranslationEntries $Paths
    $migration = Convert-ToNamespacedTranslations -Source $source -Translated $translated -Resources $resources -LegacyTranslated $legacy.Entries
    $effectiveTranslated = $migration.Entries

    $changedKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in $resources.Keys) {
        $english = [string]$resources[$key]
        if ([string]::IsNullOrWhiteSpace($english)) {
            continue
        }

        $hasCurrentKey = $source.Contains($key)
        $hasCurrentSource = $hasCurrentKey -and ([string]$source[$key] -ceq $english)
        if (($hasCurrentKey -and -not $hasCurrentSource) -or (-not $hasCurrentKey -and -not $effectiveTranslated.Contains($key))) {
            [void]$changedKeys.Add($key)
        }
    }

    $missingKeys = New-Object System.Collections.Generic.List[string]
    foreach ($key in $effectiveSource.Keys) {
        if (-not $effectiveTranslated.Contains($key) -or [string]::IsNullOrWhiteSpace([string]$effectiveTranslated[$key]) -or [string]$effectiveTranslated[$key] -eq [string]$effectiveSource[$key]) {
            $missingKeys.Add($key)
        }
    }

    $extraKeys = New-Object System.Collections.Generic.List[string]
    foreach ($key in $effectiveTranslated.Keys) {
        if (-not $effectiveSource.Contains($key)) {
            $extraKeys.Add($key)
        }
    }

    return [pscustomobject]@{
        SourceCount     = $source.Count
        TranslationCount = $effectiveTranslated.Count
        ResourceCount    = $resources.Count
        MigrationCount   = $migration.Count
        LegacyMigrationCount = $migration.LegacyCount
        LegacyTranslationPath = $legacy.Path
        ChangedKeys      = $changedKeys
        MissingKeys      = $missingKeys
        ExtraKeys        = $extraKeys
        Source           = $source
        EffectiveSource  = $effectiveSource
        Translated       = $effectiveTranslated
        Resources        = $resources
    }
}

function Test-OllamaConnection {
    param(
        [string]$Url,
        [string]$ModelName
    )

    try {
        $builder = [UriBuilder]::new($Url)
        $builder.Path = '/api/tags'
        $builder.Query = ''
        $response = Invoke-RestMethod -Uri $builder.Uri.AbsoluteUri -Method Get -TimeoutSec 10
    } catch {
        throw "Ollama non risponde su $Url. Avvia Ollama e riprova. Dettaglio: $($_.Exception.Message)"
    }

    $availableModels = @($response.models | ForEach-Object { [string]$_.name })
    if ($availableModels.Count -gt 0 -and $ModelName -notin $availableModels) {
        throw "Modello Ollama '$ModelName' non trovato. Modelli disponibili: $($availableModels -join ', ')"
    }
}

function Get-HttpErrorDetails {
    param($ErrorRecord)

    $message = [string]$ErrorRecord.Exception.Message
    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) {
        return $message
    }

    $statusCode = $null
    try { $statusCode = [int]$response.StatusCode } catch {}
    $body = ''
    try {
        $stream = $response.GetResponseStream()
        if ($stream) {
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
            try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
    } catch {}

    if (-not [string]::IsNullOrWhiteSpace($body)) {
        try {
            $errorObject = ConvertFrom-Json -InputObject $body
            if ($errorObject.error) {
                $body = [string]$errorObject.error
            }
        } catch {}
    }

    $prefix = if ($null -ne $statusCode) { "HTTP $statusCode" } else { 'Errore HTTP' }
    if ([string]::IsNullOrWhiteSpace($body)) {
        return "$prefix`: $message"
    }
    return "$prefix`: $body"
}

function Get-JsonArrayCandidates {
    param([string]$Text)

    $candidates = New-Object System.Collections.Generic.List[string]
    $start = -1
    $depth = 0
    $inString = $false
    $escaped = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $character = $Text[$i]
        if ($inString) {
            if ($escaped) {
                $escaped = $false
            } elseif ($character -eq '\') {
                $escaped = $true
            } elseif ($character -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($character -eq '"') {
            $inString = $true
        } elseif ($character -eq '[') {
            if ($depth -eq 0) {
                $start = $i
            }
            $depth++
        } elseif ($character -eq ']' -and $depth -gt 0) {
            $depth--
            if ($depth -eq 0 -and $start -ge 0) {
                $candidates.Add($Text.Substring($start, $i - $start + 1))
                $start = -1
            }
        }
    }

    return $candidates
}

function ConvertFrom-OllamaTranslationJson {
    param([string]$Text)

    $clean = $Text.Trim()
    $clean = $clean -replace '^\s*```(?:json)?\s*', ''
    $clean = $clean -replace '\s*```\s*$', ''
    $parsed = $null
    $parseError = $null

    try {
        $parsed = ConvertFrom-Json -InputObject $clean
    } catch {
        $parseError = $_.Exception.Message
    }

    if ($parsed -is [string]) {
        try {
            $parsed = ConvertFrom-Json -InputObject ([string]$parsed)
            $parseError = $null
        } catch {
            $parseError = $_.Exception.Message
            $parsed = $null
        }
    }

    if ($null -eq $parsed) {
        foreach ($candidate in @(Get-JsonArrayCandidates -Text $clean)) {
            try {
                $parsed = ConvertFrom-Json -InputObject $candidate
                $parseError = $null
                break
            } catch {
                $parseError = $_.Exception.Message
            }
        }
    }

    if ($null -eq $parsed) {
        $preview = $clean -replace '[\r\n]+', ' '
        if ($preview.Length -gt 800) {
            $preview = $preview.Substring(0, 800) + '...'
        }
        throw "Risposta JSON di Ollama non valida. $parseError Risposta: $preview"
    }

    if ($parsed -isnot [array] -and $parsed -isnot [System.Collections.IList]) {
        foreach ($propertyName in @('translations', 'items', 'result', 'data', 'output')) {
            $property = $parsed.PSObject.Properties[$propertyName]
            if ($null -ne $property -and $null -ne $property.Value) {
                $parsed = $property.Value
                break
            }
        }
    }

    if ($parsed -isnot [array] -and $parsed -isnot [System.Collections.IList]) {
        $numericProperties = @($parsed.PSObject.Properties | Where-Object { $_.Name -match '^\d+$' } | Sort-Object { [int]$_.Name })
        if ($numericProperties.Count -gt 0 -and $numericProperties.Count -eq @($parsed.PSObject.Properties).Count) {
            $parsed = @($numericProperties | ForEach-Object {
                [pscustomobject]@{ index = [int]$_.Name; translation = [string]$_.Value }
            })
        }
    }

    if ($parsed -isnot [array] -and $parsed -isnot [System.Collections.IList]) {
        $parsed = @($parsed)
    }

    return $parsed
}

function Invoke-OllamaTranslation {
    param(
        [string[]]$Strings,
        [string[]]$Keys,
        [string]$ModelName,
        [string]$Url
    )

    if ($Strings.Count -eq 0) {
        return @()
    }

    $protectedStrings = New-Object System.Collections.Generic.List[object]
    $tokenMaps = New-Object System.Collections.Generic.List[object]

    for ($i = 0; $i -lt $Strings.Count; $i++) {
        $item = $Strings[$i]
        $protected = Protect-Text $item
        $protectedStrings.Add([pscustomobject]@{
            index = $i
            key = $(if ($Keys -and $i -lt $Keys.Count) { $Keys[$i] } else { "item_$i" })
            text = $protected.Text
        })
        $tokenMaps.Add($protected.Map)
    }

    $prompt = @"
/no_think
Translate each source text to natural Italian for a videogame localization.
Most source text is English, but language names or labels may use another script.

STRICT RULES:

- Return ONLY one JSON object with a `translations` array.
- Same number of elements as input.
- Do NOT modify tokens like __TOKEN_0__.
- Keep all tokens exactly unchanged.
- Do not add explanations.
- Do not add comments.
- Do not use markdown.
- Preserve punctuation.
- Preserve the exact meaning, numbers, subjects and targets. Do not add or remove gameplay information.
- Preserve game terminology consistency.
- Write concise, idiomatic Italian. Never translate mechanically word by word.
- Card and ability descriptions must read as natural gameplay instructions.
- Prefer Italian verbs such as "infligge", "ottiene", "recupera", "cura" according to the actual subject.
- Example: "Target ally heals __TOKEN_0__ __TOKEN_1__." becomes "L'alleato bersaglio recupera __TOKEN_0__ __TOKEN_1__."
- Example: "Deal __TOKEN_0__ damage to target enemy." becomes "Infliggi __TOKEN_0__ danni al nemico bersaglio."
- Use "al nemico", never the ungrammatical form "all' nemico".
- Use the `key` field as context, but never translate or return the key.
- Do not invent character names or replace a role with a character name.
- Keep proper names unchanged unless the text is clearly a translatable role or label.
- Each item in `translations` must contain only the fields `index` and `translation`.
- Keep each `index` identical to the input item index.
- Preserve the order by index.
- Required shape: {"translations":[{"index":0,"translation":"testo italiano"}]}

INPUT:

$($protectedStrings | ConvertTo-Json -Compress -Depth 4)
"@.Trim()

    $payload = @{
        model = $ModelName
        prompt = $prompt
        stream = $false
        think = $false
        format = 'json'
        keep_alive = '30m'
        options = @{
            temperature = 0
        }
    } | ConvertTo-Json -Depth 6 -Compress

    $payloadBytes = [Text.Encoding]::UTF8.GetBytes($payload)
    try {
        $response = Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json; charset=utf-8' -Body $payloadBytes -TimeoutSec 900
    } catch {
        throw (Get-HttpErrorDetails $_)
    }
    $result = [string]$response.response
    $translated = @(ConvertFrom-OllamaTranslationJson -Text $result)
    $final = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Strings.Count; $i++) {
        $final.Add('')
    }

    if ($translated.Count -gt 0) {
        $seen = 0
        $seenIndices = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($item in $translated) {
            $targetIndex = $null
            $text = $null

            if ($item -is [string]) {
                $targetIndex = $seen
                $text = [string]$item
            } else {
                if ($null -ne $item.PSObject.Properties['index']) {
                    $targetIndex = [int]$item.index
                } elseif ($null -ne $item.PSObject.Properties['translation']) {
                    $targetIndex = $seen
                }

                if ($null -ne $item.PSObject.Properties['translation']) {
                    $text = [string]$item.translation
                } elseif ($null -ne $item.PSObject.Properties['text']) {
                    $text = [string]$item.text
                } else {
                    $text = [string]$item
                }
            }

            if ($null -ne $targetIndex -and $targetIndex -ge 0 -and $targetIndex -lt $Strings.Count -and $seenIndices.Add($targetIndex)) {
                foreach ($token in $tokenMaps[$targetIndex].Keys) {
                    if (-not $text.Contains([string]$token)) {
                        throw "Token protetto mancante nell'indice $targetIndex`: $token"
                    }
                }
                $text = Restore-Text -Text $text -Map $tokenMaps[$targetIndex]
                $final[$targetIndex] = $text
            } elseif ($null -ne $targetIndex) {
                throw "Indice duplicato o non valido nella risposta di Ollama: $targetIndex"
            }
            $seen++
        }
    } else {
        throw "Formato inatteso da Ollama."
    }

    for ($i = 0; $i -lt $final.Count; $i++) {
        if ([string]::IsNullOrWhiteSpace($final[$i])) {
            throw "Traduzione mancante per l'indice $i"
        }
    }

    return $final
}

function Invoke-OllamaTranslationReliable {
    param(
        [string[]]$Strings,
        [string[]]$Keys,
        [string]$ModelName,
        [string]$Url
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            return @(Invoke-OllamaTranslation -Strings $Strings -Keys $Keys -ModelName $ModelName -Url $Url)
        } catch {
            $lastError = $_
            if ($attempt -lt 2) {
                Write-Log "Risposta non valida, nuovo tentativo del batch..."
                Start-Sleep -Milliseconds 500
            }
        }
    }

    $details = Format-ExceptionDetails $lastError
    $canSplit = $Strings.Count -gt 1 -and $details -match 'JSON|Formato|indice|element|Token protetto|Traduzione mancante|HTTP 400|Richiesta non valida|context length|too long'
    if (-not $canSplit) {
        throw $lastError
    }

    $middle = [int][Math]::Ceiling($Strings.Count / 2.0)
    Write-Log "Batch non valido: suddivisione automatica in $middle e $($Strings.Count - $middle) stringhe."
    $leftKeys = if ($Keys) { @($Keys[0..($middle - 1)]) } else { @() }
    $rightKeys = if ($Keys) { @($Keys[$middle..($Keys.Count - 1)]) } else { @() }
    $left = @(Invoke-OllamaTranslationReliable -Strings @($Strings[0..($middle - 1)]) -Keys $leftKeys -ModelName $ModelName -Url $Url)
    $right = @(Invoke-OllamaTranslationReliable -Strings @($Strings[$middle..($Strings.Count - 1)]) -Keys $rightKeys -ModelName $ModelName -Url $Url)
    return @($left + $right)
}

function New-TranslationBatches {
    param(
        [System.Collections.Generic.List[string]]$Keys,
        $Source
    )

    $batches = New-Object System.Collections.Generic.List[object]
    $currentKeys = New-Object System.Collections.Generic.List[string]
    $currentCharacters = 0

    foreach ($key in $Keys) {
        $length = ([string]$Source[$key]).Length
        $wouldOverflow = $currentKeys.Count -gt 0 -and (
            $currentKeys.Count -ge $script:BatchMaxItems -or
            ($currentCharacters + $length) -gt $script:BatchMaxCharacters
        )
        if ($wouldOverflow) {
            $batches.Add(@($currentKeys.ToArray()))
            $currentKeys.Clear()
            $currentCharacters = 0
        }

        $currentKeys.Add($key)
        $currentCharacters += $length
    }

    if ($currentKeys.Count -gt 0) {
        $batches.Add(@($currentKeys.ToArray()))
    }
    return $batches
}

function Backup-TranslationSnapshot {
    param($Paths)

    if (-not (Test-Path -LiteralPath $Paths.TranslatedFile)) {
        return
    }

    New-Item -ItemType Directory -Force -Path $Paths.HistoryRoot | Out-Null
    $snapshot = Join-Path $Paths.HistoryRoot ("Italian_translated_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Copy-Item -LiteralPath $Paths.TranslatedFile -Destination $snapshot -Force

    $oldSnapshots = @(Get-ChildItem -LiteralPath $Paths.HistoryRoot -Filter 'Italian_translated_*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5)
    foreach ($oldSnapshot in $oldSnapshots) {
        Remove-Item -LiteralPath $oldSnapshot.FullName -Force
    }
    Write-Log "Backup della traduzione creato: $([IO.Path]::GetFileName($snapshot))"
}

function Save-WorkingFiles {
    param(
        $Paths,
        $Source,
        $Work,
        $Translated
    )

    Write-LocaleEntries -Path $Paths.SourceFile -Entries $Source
    Write-LocaleEntries -Path $Paths.WorkFile -Entries $Work
    Write-LocaleEntries -Path $Paths.TranslatedFile -Entries $Translated
}

function Build-ReleasePackage {
    param($Paths)

    Ensure-PackageFolders $Paths
    if (-not (Test-Path -LiteralPath $Paths.ReleaseDll)) {
        throw "Template DLL non trovato nella release: $($Paths.ReleaseDll)"
    }
    if (-not (Test-Path -LiteralPath $Paths.TranslatedFile)) {
        throw "File tradotto non trovato: $($Paths.TranslatedFile)"
    }

    $entries = Read-LocaleEntries $Paths.TranslatedFile
    $mainCount = @($entries.Keys | Where-Object { [string]$_ -like 'main::*' }).Count
    $customCount = @($entries.Keys | Where-Object { [string]$_ -like 'custom::*' }).Count
    if ($mainCount -eq 0 -or $customCount -eq 0) {
        throw "Traduzione incompleta o obsoleta: mancano i namespace main/custom. Esegui 'Generate mod'."
    }

    Copy-Item -LiteralPath $Paths.TranslatedFile -Destination $Paths.ReleaseJson -Force
    Write-Log "Release aggiornata: Italian_translated.json ($mainCount main, $customCount custom)"
}

function Invoke-SyncTranslation {
    param(
        $Paths,
        [switch]$ForceReview
    )

    Ensure-PackageFolders $Paths
    Set-UiStatus -Message 'Verifica di Ollama...' -Marquee
    Test-OllamaConnection -Url $script:OllamaUrl -ModelName $script:Model
    Set-UiStatus -Message 'Analisi dei testi del gioco...' -Marquee
    Write-Log "Analisi file: $($Paths.ResourcesAssets)"

    $analysis = Get-TranslationAnalysis $Paths

    Write-Log "Testi nel gioco: $($analysis.ResourceCount)"
    Write-Log "Chiavi sorgente: $($analysis.SourceCount)"
    Write-Log "Chiavi tradotte: $($analysis.TranslationCount)"
    if ($analysis.MigrationCount -gt 0) {
        Write-Log "Traduzioni legacy recuperate: $($analysis.MigrationCount)"
    }
    if ($analysis.LegacyMigrationCount -gt 0) {
        Write-Log "Traduzioni recuperate dai backup precedenti: $($analysis.LegacyMigrationCount)"
    }
    Write-Log "Chiavi nuove o modificate: $($analysis.ChangedKeys.Count)"
    Write-Log "Chiavi mancanti o ancora in inglese: $($analysis.MissingKeys.Count)"
    if ($analysis.ExtraKeys.Count -gt 0) {
        Write-Log "Chiavi extra nella traduzione: $($analysis.ExtraKeys.Count)"
    }

    $updatedSource = Copy-OrderedDictionary $analysis.EffectiveSource
    $updatedWork = Copy-OrderedDictionary $analysis.EffectiveSource
    $updatedTranslated = Copy-OrderedDictionary $analysis.Translated

    $toTranslate = New-Object System.Collections.Generic.List[string]
    $structuralReviewCount = 0
    foreach ($key in $updatedSource.Keys) {
        $sourceValue = [string]$updatedSource[$key]
        $needsTranslation = $false

        if ($ForceReview -and -not [string]::IsNullOrWhiteSpace($sourceValue)) {
            $needsTranslation = $true
        } elseif ($analysis.ChangedKeys.Contains($key)) {
            $needsTranslation = $true
        } elseif (-not $updatedTranslated.Contains($key)) {
            $needsTranslation = $true
        } elseif ([string]::IsNullOrWhiteSpace([string]$updatedTranslated[$key])) {
            $needsTranslation = $true
        } elseif ([string]$updatedTranslated[$key] -eq $sourceValue) {
            $needsTranslation = $true
        } elseif (-not (Test-TranslationStructure -SourceText $sourceValue -TranslatedText ([string]$updatedTranslated[$key]))) {
            $needsTranslation = $true
            $structuralReviewCount++
        }

        if ($needsTranslation) {
            $toTranslate.Add($key)
        }
    }

    if ($structuralReviewCount -gt 0) {
        Write-Log "Traduzioni obsolete o con token incoerenti da correggere: $structuralReviewCount"
    }

    if ($toTranslate.Count -eq 0) {
        Write-Log 'Nessuna traduzione da aggiornare.'
    } else {
        Backup-TranslationSnapshot $Paths

        # Persist pending entries as source text before translation. If the
        # operation stops, the next Sync will reliably resume these keys.
        foreach ($key in $toTranslate) {
            $updatedTranslated[$key] = [string]$updatedSource[$key]
        }
        Save-WorkingFiles -Paths $Paths -Source $updatedSource -Work $updatedWork -Translated $updatedTranslated

        $batches = New-TranslationBatches -Keys $toTranslate -Source $updatedSource
        $totalBatches = $batches.Count
        Set-UiStatus -Message "Traduzione incrementale: $($toTranslate.Count) stringhe" -Value 0 -Maximum $totalBatches
        Write-Log "Da tradurre: $($toTranslate.Count) stringhe in $totalBatches batch"

        for ($i = 0; $i -lt $totalBatches; $i++) {
            $batchKeys = @($batches[$i])
            $batchValues = @($batchKeys | ForEach-Object { [string]$updatedSource[$_] })

            Set-UiStatus -Message ("Traduzione batch {0}/{1}" -f ($i + 1), $totalBatches) -Value $i -Maximum $totalBatches
            Write-Log ("Traduzione batch {0}/{1}: {2} stringhe, {3} caratteri" -f ($i + 1), $totalBatches, $batchKeys.Count, (($batchValues | ForEach-Object Length | Measure-Object -Sum).Sum))

            $translatedValues = @(Invoke-OllamaTranslationReliable -Strings $batchValues -Keys $batchKeys -ModelName $script:Model -Url $script:OllamaUrl)
            $previewLines = New-Object System.Collections.Generic.List[string]

            for ($j = 0; $j -lt $batchKeys.Count; $j++) {
                $key = $batchKeys[$j]
                $value = $translatedValues[$j]
                $updatedTranslated[$key] = $value
                $updatedWork[$key] = [string]$updatedSource[$key]
                if ($previewLines.Count -lt 4) {
                    $previewLines.Add(("  {0} -> {1}" -f $key, (Format-PreviewText $value)))
                }
            }

            if ($previewLines.Count -gt 0) {
                if ($batchKeys.Count -gt $previewLines.Count) {
                    $previewLines.Add("  ...")
                }
                Write-Log ($previewLines -join [Environment]::NewLine)
            }

            if ((($i + 1) % $script:CheckpointEveryBatches) -eq 0 -or ($i + 1) -eq $totalBatches) {
                Save-WorkingFiles -Paths $Paths -Source $updatedSource -Work $updatedWork -Translated $updatedTranslated
                Write-Log ("Checkpoint salvato: batch {0}/{1}" -f ($i + 1), $totalBatches)
            }

            Set-UiStatus -Message ("Traduzione batch {0}/{1} completato" -f ($i + 1), $totalBatches) -Value ($i + 1) -Maximum $totalBatches
        }
    }

    Save-WorkingFiles -Paths $Paths -Source $updatedSource -Work $updatedWork -Translated $updatedTranslated
    Write-Log 'Controllo finale di chiavi e token...'
    Invoke-ValidateTranslation $Paths
    Build-ReleasePackage $Paths
    Write-Log 'Sincronizzazione incrementale completata.'
}

function Invoke-InstallMod {
    param($Paths)

    Ensure-PackageFolders $Paths
    Assert-GameInstallation $Paths.GameRoot
    Build-ReleasePackage $Paths

    New-Item -ItemType Directory -Force -Path $Paths.GameManaged, $Paths.GameLocales, $Paths.InstallBackupRoot | Out-Null

    if ((Test-Path -LiteralPath $Paths.GameLocaleDll) -and -not (Test-Path -LiteralPath $Paths.BackupDll)) {
        $currentDllHash = (Get-FileHash -LiteralPath $Paths.GameLocaleDll -Algorithm SHA256).Hash
        $releaseDllHash = (Get-FileHash -LiteralPath $Paths.ReleaseDll -Algorithm SHA256).Hash
        if ($currentDllHash -cne $releaseDllHash) {
            Copy-Item -LiteralPath $Paths.GameLocaleDll -Destination $Paths.BackupDll -Force
            Write-Log 'Backup del Locale.dll originale creato.'
        }
    }

    if ((Test-Path -LiteralPath $Paths.GameLocaleJson) -and -not (Test-Path -LiteralPath $Paths.BackupJson)) {
        $currentJsonHash = (Get-FileHash -LiteralPath $Paths.GameLocaleJson -Algorithm SHA256).Hash
        $releaseJsonHash = (Get-FileHash -LiteralPath $Paths.ReleaseJson -Algorithm SHA256).Hash
        if ($currentJsonHash -cne $releaseJsonHash) {
            Copy-Item -LiteralPath $Paths.GameLocaleJson -Destination $Paths.BackupJson -Force
            Write-Log 'Backup del JSON precedente creato.'
        }
    }

    Copy-Item -LiteralPath $Paths.ReleaseDll -Destination $Paths.GameLocaleDll -Force
    Copy-Item -LiteralPath $Paths.ReleaseJson -Destination $Paths.GameLocaleJson -Force

    $dllExpected = (Get-FileHash -LiteralPath $Paths.ReleaseDll -Algorithm SHA256).Hash
    $dllInstalled = (Get-FileHash -LiteralPath $Paths.GameLocaleDll -Algorithm SHA256).Hash
    $jsonExpected = (Get-FileHash -LiteralPath $Paths.ReleaseJson -Algorithm SHA256).Hash
    $jsonInstalled = (Get-FileHash -LiteralPath $Paths.GameLocaleJson -Algorithm SHA256).Hash
    if ($dllExpected -cne $dllInstalled -or $jsonExpected -cne $jsonInstalled) {
        throw 'Verifica installazione fallita: i file copiati non coincidono con la release.'
    }

    if (Test-Path -LiteralPath $Paths.GameLegacyPatchDll) {
        Remove-Item -LiteralPath $Paths.GameLegacyPatchDll -Force
    }

    Write-Log "Mod italiana installata e verificata in: $($Paths.GameRoot)"
}

function Invoke-UninstallMod {
    param($Paths)

    New-Item -ItemType Directory -Force -Path $Paths.GameManaged, $Paths.GameLocales, $Paths.InstallBackupRoot | Out-Null

    if (Test-Path -LiteralPath $Paths.BackupDll) {
        Copy-Item -LiteralPath $Paths.BackupDll -Destination $Paths.GameLocaleDll -Force
        Write-Log 'Locale.dll originale ripristinato.'
    } elseif (Test-Path -LiteralPath $Paths.GameLocaleDll) {
        Remove-Item -LiteralPath $Paths.GameLocaleDll -Force
    }

    if (Test-Path -LiteralPath $Paths.BackupJson) {
        Copy-Item -LiteralPath $Paths.BackupJson -Destination $Paths.GameLocaleJson -Force
        Write-Log 'JSON originale ripristinato.'
    } elseif (Test-Path -LiteralPath $Paths.GameLocaleJson) {
        Remove-Item -LiteralPath $Paths.GameLocaleJson -Force
    }

    if (Test-Path -LiteralPath $Paths.GameLegacyPatchDll) {
        Remove-Item -LiteralPath $Paths.GameLegacyPatchDll -Force
    }

    Write-Log 'Mod italiana rimossa.'
}

function Invoke-ValidateTranslation {
    param($Paths)

    $sourceEntries = Read-LocaleEntries $Paths.SourceFile
    $translatedEntries = Read-LocaleEntries $Paths.TranslatedFile
    $errors = New-Object System.Collections.Generic.List[string]
    $extraKeys = New-Object System.Collections.Generic.List[string]

    $sourceMap = @{}
    foreach ($entry in $sourceEntries.GetEnumerator()) {
        if (-not $sourceMap.ContainsKey($entry.Key)) {
            $sourceMap[$entry.Key] = $entry.Value
        }
    }

    $translatedMap = @{}
    foreach ($entry in $translatedEntries.GetEnumerator()) {
        if ($sourceMap.ContainsKey($entry.Key)) {
            $translatedMap[$entry.Key] = $entry.Value
        } else {
            $extraKeys.Add($entry.Key)
        }
    }

    foreach ($sourceEntry in $sourceEntries.GetEnumerator()) {
        if (-not $translatedMap.ContainsKey($sourceEntry.Key)) {
            $errors.Add("Chiave mancante nella traduzione: '$($sourceEntry.Key)'")
            continue
        }

        $translatedValue = [string]$translatedMap[$sourceEntry.Key]
        if (-not [string]::IsNullOrWhiteSpace([string]$sourceEntry.Value) -and [string]::IsNullOrWhiteSpace($translatedValue)) {
            $errors.Add("Traduzione vuota nella chiave '$($sourceEntry.Key)'")
            continue
        }

        if (-not (Test-TranslationStructure -SourceText ([string]$sourceEntry.Value) -TranslatedText $translatedValue)) {
            $errors.Add("Token protetti o formato modificati nella chiave '$($sourceEntry.Key)'")
        }
    }

    if ($errors.Count -gt 0) {
        foreach ($error in $errors) {
            Write-Log $error
        }
        throw 'Validazione fallita.'
    }

    $changed = 0
    foreach ($sourceEntry in $sourceEntries.GetEnumerator()) {
        if ($translatedMap[$sourceEntry.Key] -cne $sourceEntry.Value) {
            $changed++
        }
    }

    $message = "Validazione superata: $($sourceEntries.Count) chiavi sorgente, $changed tradotte, $($sourceEntries.Count - $changed) ancora in inglese."
    if ($extraKeys.Count -gt 0) {
        $message += " Chiavi extra: $($extraKeys -join ', ')."
    }

    Write-Log $message
}

function Invoke-Action {
    param(
        [ValidateSet('Analyze', 'Sync', 'Review', 'Install', 'Uninstall', 'Validate')]
        [string]$Name,
        [string]$Root,
        [string]$ModelName,
        [string]$Url
    )

    Assert-GameInstallation $Root
    Save-GameInstallation $Root
    $paths = Get-PackagePaths $Root
    $script:Model = $ModelName
    $script:OllamaUrl = $Url

    switch ($Name) {
        'Analyze' {
            Set-UiStatus -Message 'Analisi dei testi del gioco...' -Marquee
            $analysis = Get-TranslationAnalysis $paths
            Write-Log "Testi nel gioco: $($analysis.ResourceCount)"
            Write-Log "Chiavi sorgente: $($analysis.SourceCount)"
            Write-Log "Chiavi tradotte: $($analysis.TranslationCount)"
            if ($analysis.MigrationCount -gt 0) {
                Write-Log "Traduzioni legacy recuperabili: $($analysis.MigrationCount)"
            }
            if ($analysis.LegacyMigrationCount -gt 0) {
                Write-Log "Traduzioni recuperabili dai backup precedenti: $($analysis.LegacyMigrationCount)"
            }
            Write-Log "Chiavi nuove o modificate: $($analysis.ChangedKeys.Count)"
            Write-Log "Chiavi mancanti o ancora in inglese: $($analysis.MissingKeys.Count)"
            if ($analysis.ExtraKeys.Count -gt 0) {
                Write-Log "Chiavi extra nella traduzione: $($analysis.ExtraKeys.Count)"
            }
            Set-UiStatus -Message 'Analisi completata' -Value 1 -Maximum 1
        }
        'Sync' {
            $syncMutex = Enter-ToolMutex 'Sync'
            try {
                Invoke-SyncTranslation $paths
            } finally {
                try { $syncMutex.ReleaseMutex() } catch {}
                $syncMutex.Dispose()
            }
        }
        'Review' {
            $syncMutex = Enter-ToolMutex 'Sync'
            try {
                Invoke-SyncTranslation $paths -ForceReview
            } finally {
                try { $syncMutex.ReleaseMutex() } catch {}
                $syncMutex.Dispose()
            }
        }
        'Install' { Invoke-InstallMod $paths }
        'Uninstall' { Invoke-UninstallMod $paths }
        'Validate' { Invoke-ValidateTranslation $paths }
    }
}

function Invoke-UiOperation {
    param(
        [string]$Name,
        [string]$RootText,
        [string]$ModelText,
        [string]$UrlText
    )

    $resolvedRoot = Find-GameInstallation -Preferred $RootText
    if ([string]::IsNullOrWhiteSpace($resolvedRoot)) {
        [Windows.Forms.MessageBox]::Show(
            "Cartella del gioco non valida. Seleziona la cartella che contiene 'Hunters Moon.exe'.",
            'Italian Translator'
        ) | Out-Null
        return
    }
    $RootText = $resolvedRoot
    Save-GameInstallation $RootText
    if ($script:Ui.RootBox) {
        $script:Ui.RootBox.Text = $RootText
    }

    if ($script:UiState.Busy) {
        Write-Log 'Operazione già in corso.'
        return
    }

    $script:UiState.Busy = $true
    foreach ($button in $script:Ui.Buttons) {
        $button.Enabled = $false
    }
    $script:Ui.Form.UseWaitCursor = $true
    $script:Ui.Log.Clear()
    Set-UiStatus -Message "Avvio: $Name" -Value 0 -Maximum 1

    $hostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("italiantranslator_{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    $stdoutPath = Join-Path $tempDir 'stdout.log'
    $stderrPath = Join-Path $tempDir 'stderr.log'

    $command = New-ScriptInvocationCommand -ActionName $Name -Root $RootText -ModelName $ModelText -Url $UrlText -WithEventStream
    $arguments = "-NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand $(ConvertTo-EncodedCommand $command)"

    $process = Start-Process -FilePath $hostExe -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    $script:UiState.Operation = [pscustomobject]@{
        Process = $process
        OutputPath = $stdoutPath
        ErrorPath = $stderrPath
        OutputOffset = 0L
        ErrorOffset = 0L
        OutputRemainder = ''
        ErrorRemainder = ''
        OutputDecoder = [System.Text.UTF8Encoding]::new($false, $false).GetDecoder()
        ErrorDecoder = [System.Text.UTF8Encoding]::new($false, $false).GetDecoder()
        Cancelled = $false
        TempDir = $tempDir
    }
    if ($script:Ui.CancelButton) {
        $script:Ui.CancelButton.Enabled = $true
    }
}

function Show-TranslatorGui {
    try {
        $script:UiMutex = Enter-ToolMutex 'Gui'
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Italian Translator') | Out-Null
        return
    }

    $initialGameRoot = Find-GameInstallation -Preferred $GameRoot

    $form = New-Object System.Windows.Forms.Form
    $form.SuspendLayout()
    $form.Text = "Italian Translator"
    $form.StartPosition = 'CenterScreen'
    $form.Width = 980
    $form.Height = 720
    $doubleBuffered = $form.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic')
    if ($doubleBuffered) {
        $doubleBuffered.SetValue($form, $true, $null)
    }

    $rootLabel = New-Object System.Windows.Forms.Label
    $rootLabel.Text = 'Game root'
    $rootLabel.Left = 12
    $rootLabel.Top = 15
    $rootLabel.Width = 80

    $rootBox = New-Object System.Windows.Forms.TextBox
    $rootBox.Left = 100
    $rootBox.Top = 12
    $rootBox.Width = 760
    $rootBox.Anchor = 'Top,Left,Right'
    $rootBox.Text = $initialGameRoot

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = 'Browse'
    $browseButton.Left = 870
    $browseButton.Top = 10
    $browseButton.Width = 80
    $browseButton.Anchor = 'Top,Right'

    $modelLabel = New-Object System.Windows.Forms.Label
    $modelLabel.Text = 'Model'
    $modelLabel.Left = 12
    $modelLabel.Top = 46
    $modelLabel.Width = 80

    $modelBox = New-Object System.Windows.Forms.TextBox
    $modelBox.Left = 100
    $modelBox.Top = 43
    $modelBox.Width = 330
    $modelBox.Text = $script:Model

    $urlLabel = New-Object System.Windows.Forms.Label
    $urlLabel.Text = 'Ollama URL'
    $urlLabel.Left = 450
    $urlLabel.Top = 46
    $urlLabel.Width = 80

    $urlBox = New-Object System.Windows.Forms.TextBox
    $urlBox.Left = 540
    $urlBox.Top = 43
    $urlBox.Width = 410
    $urlBox.Anchor = 'Top,Left,Right'
    $urlBox.Text = $script:OllamaUrl

    $analyzeButton = New-Object System.Windows.Forms.Button
    $analyzeButton.Text = 'Analyze'
    $analyzeButton.Left = 12
    $analyzeButton.Top = 78
    $analyzeButton.Width = 105

    $syncButton = New-Object System.Windows.Forms.Button
    $syncButton.Text = 'Generate mod'
    $syncButton.Left = 125
    $syncButton.Top = 78
    $syncButton.Width = 105

    $reviewButton = New-Object System.Windows.Forms.Button
    $reviewButton.Text = 'Review all'
    $reviewButton.Left = 238
    $reviewButton.Top = 78
    $reviewButton.Width = 105

    $installButton = New-Object System.Windows.Forms.Button
    $installButton.Text = 'Install'
    $installButton.Left = 351
    $installButton.Top = 78
    $installButton.Width = 105

    $uninstallButton = New-Object System.Windows.Forms.Button
    $uninstallButton.Text = 'Uninstall'
    $uninstallButton.Left = 464
    $uninstallButton.Top = 78
    $uninstallButton.Width = 105

    $validateButton = New-Object System.Windows.Forms.Button
    $validateButton.Text = 'Validate'
    $validateButton.Left = 577
    $validateButton.Top = 78
    $validateButton.Width = 105

    $openButton = New-Object System.Windows.Forms.Button
    $openButton.Text = 'Open folder'
    $openButton.Left = 690
    $openButton.Top = 78
    $openButton.Width = 105

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Left = 803
    $cancelButton.Top = 78
    $cancelButton.Width = 105
    $cancelButton.Enabled = $false

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Left = 12
    $progress.Top = 116
    $progress.Width = 938
    $progress.Height = 18
    $progress.Anchor = 'Top,Left,Right'
    $progress.Minimum = 0
    $progress.Maximum = 1

    $status = New-Object System.Windows.Forms.Label
    $status.Left = 12
    $status.Top = 140
    $status.Width = 938
    $status.Height = 20
    $status.Anchor = 'Top,Left,Right'
    $status.Text = 'Ready'

    $log = New-Object System.Windows.Forms.RichTextBox
    $log.Left = 12
    $log.Top = 166
    $log.Width = 938
    $log.Height = 500
    $log.Anchor = 'Top,Bottom,Left,Right'
    $log.ReadOnly = $true
    $log.Font = New-Object System.Drawing.Font('Consolas', 9)

    $script:Ui = [pscustomobject]@{
        Form = $form
        Progress = $progress
        Status = $status
        Log = $log
        RootBox = $rootBox
        Buttons = @($analyzeButton, $syncButton, $reviewButton, $installButton, $uninstallButton, $validateButton, $openButton, $browseButton)
        CancelButton = $cancelButton
        Busy = $false
        Timer = $null
    }

    $script:UiState = [pscustomobject]@{
        Queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        Status = 'Ready'
        Value = 0
        Maximum = 1
        Marquee = $false
        Busy = $false
        Operation = $null
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $timer.Add_Tick({
        Flush-UiState
        Update-UiOperation
    })
    $timer.Start()
    $script:Ui.Timer = $timer

    $form.Add_FormClosing({
        if ($script:Ui.Timer) {
            $script:Ui.Timer.Stop()
            $script:Ui.Timer.Dispose()
        }
        if ($script:UiState.Operation -and -not $script:UiState.Operation.Process.HasExited) {
            try { Stop-Process -Id $script:UiState.Operation.Process.Id -Force } catch {}
        }
        $script:UiState.Operation = $null
        Flush-UiState
    })

    $browseButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Select the game root folder'
        $dialog.SelectedPath = $rootBox.Text
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            if (Test-GameInstallation $dialog.SelectedPath) {
                $rootBox.Text = [IO.Path]::GetFullPath($dialog.SelectedPath)
                Save-GameInstallation $rootBox.Text
            } else {
                [Windows.Forms.MessageBox]::Show(
                    "La cartella scelta non contiene 'Hunters Moon.exe'.",
                    'Italian Translator'
                ) | Out-Null
            }
        }
    })

    $openButton.Add_Click({
        if (Test-Path -LiteralPath $rootBox.Text) {
            Start-Process -FilePath $rootBox.Text
        } else {
            [System.Windows.Forms.MessageBox]::Show('Game root non trovato.', 'Italian Translator') | Out-Null
        }
    })

    $cancelButton.Add_Click({
        if ($script:UiState.Operation -and -not $script:UiState.Operation.Process.HasExited) {
            try {
                $script:UiState.Operation.Cancelled = $true
                Stop-Process -Id $script:UiState.Operation.Process.Id -Force
                Write-Log 'Operazione annullata.'
                Set-UiStatus -Message 'Operazione annullata' -Value 0 -Maximum 1
            } catch {
                Write-Log ("Impossibile annullare l'operazione: " + $_.Exception.Message)
            }
        }
    })

    $analyzeButton.Add_Click({
        Invoke-UiOperation -Name 'Analyze' -RootText $rootBox.Text -ModelText $modelBox.Text -UrlText $urlBox.Text
    })

    $syncButton.Add_Click({
        Invoke-UiOperation -Name 'Sync' -RootText $rootBox.Text -ModelText $modelBox.Text -UrlText $urlBox.Text
    })

    $reviewButton.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show(
            'La revisione ritraduce tutte le voci e crea prima un backup. Continuare?',
            'Revisione completa',
            [System.Windows.Forms.MessageBoxButtons]::YesNo
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            Invoke-UiOperation -Name 'Review' -RootText $rootBox.Text -ModelText $modelBox.Text -UrlText $urlBox.Text
        }
    })

    $installButton.Add_Click({
        Invoke-UiOperation -Name 'Install' -RootText $rootBox.Text -ModelText $modelBox.Text -UrlText $urlBox.Text
    })

    $uninstallButton.Add_Click({
        Invoke-UiOperation -Name 'Uninstall' -RootText $rootBox.Text -ModelText $modelBox.Text -UrlText $urlBox.Text
    })

    $validateButton.Add_Click({
        Invoke-UiOperation -Name 'Validate' -RootText $rootBox.Text -ModelText $modelBox.Text -UrlText $urlBox.Text
    })

    $form.Controls.AddRange(@(
        $rootLabel, $rootBox, $browseButton,
        $modelLabel, $modelBox, $urlLabel, $urlBox,
        $analyzeButton, $syncButton, $reviewButton, $installButton, $uninstallButton, $validateButton, $openButton, $cancelButton,
        $progress, $status, $log
    ))

    $form.ResumeLayout($false)
    Flush-UiState
    try {
        [void]$form.ShowDialog()
    } finally {
        if ($script:UiMutex) {
            try { $script:UiMutex.ReleaseMutex() } catch {}
            $script:UiMutex.Dispose()
            $script:UiMutex = $null
        }
    }
}

if ($Action -eq 'Gui') {
    Ensure-PackageFolders (Get-PackagePaths $PSScriptRoot)
    Show-TranslatorGui
    return
}

try {
    $GameRoot = Find-GameInstallation -Preferred $GameRoot
    Assert-GameInstallation $GameRoot
    $paths = Get-PackagePaths $GameRoot
    Ensure-PackageFolders $paths
    Invoke-Action -Name $Action -Root $GameRoot -ModelName $Model -Url $OllamaUrl
} catch {
    $details = $_.Exception.Message
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        $details += [Environment]::NewLine + $_.InvocationInfo.PositionMessage.Trim()
    }
    [Console]::Error.WriteLine("Errore: $details")
    exit 1
}

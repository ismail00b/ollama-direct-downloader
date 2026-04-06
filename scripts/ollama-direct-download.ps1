[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$ModelRef,

    [Parameter()]
    [string]$ModelsRoot,

    [Parameter()]
    [ValidateRange(1, 32)]
    [int]$MaxConcurrency = 8,

    [switch]$Force,

    [switch]$SkipManifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ModelRef {
    param([string]$InputRef)

    $parts = $InputRef.Split(':', 2)
    if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
        throw "ModelRef must be in the form 'model:tag' (example: gemma2:2b)."
    }

    $modelName = $parts[0].Trim()
    $tag = $parts[1].Trim()
    $modelPath = if ($modelName.Contains('/')) { $modelName } else { "library/$modelName" }

    [PSCustomObject]@{
        ModelName = $modelName
        ModelPath = $modelPath
        Tag      = $tag
    }
}

function Get-DefaultModelsRoot {
    if ($env:OLLAMA_MODELS -and -not [string]::IsNullOrWhiteSpace($env:OLLAMA_MODELS)) {
        return $env:OLLAMA_MODELS
    }

    return (Join-Path $HOME '.ollama/models')
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -ItemType Directory -Path $Path -Force)
    }
}

function New-HttpClient {
    $handler = [System.Net.Http.SocketsHttpHandler]::new()
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $handler.PooledConnectionLifetime = [TimeSpan]::FromMinutes(5)

    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('ollama-direct-download-ps/1.0')
    return $client
}

function Download-Text {
    param(
        [System.Net.Http.HttpClient]$Client,
        [string]$Url
    )

    $response = $Client.GetAsync($Url).GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
        throw "GET $Url failed with HTTP $([int]$response.StatusCode) $($response.ReasonPhrase)"
    }

    return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
}

function Download-File {
    param(
        [System.Net.Http.HttpClient]$Client,
        [string]$Url,
        [string]$OutFile,
        [Nullable[long]]$ExpectedBytes
    )

    $tempFile = "$OutFile.part"
    try {
        $response = $Client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "GET $Url failed with HTTP $([int]$response.StatusCode) $($response.ReasonPhrase)"
        }

        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fs = [System.IO.File]::Open($tempFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

        try {
            $stream.CopyTo($fs)
        }
        finally {
            $fs.Dispose()
            $stream.Dispose()
            $response.Dispose()
        }

        if ($ExpectedBytes.HasValue) {
            $actual = (Get-Item -LiteralPath $tempFile).Length
            if ($actual -ne $ExpectedBytes.Value) {
                throw "Size mismatch for $OutFile. Expected $($ExpectedBytes.Value), got $actual."
            }
        }

        Move-Item -LiteralPath $tempFile -Destination $OutFile -Force
    }
    catch {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

$model = Resolve-ModelRef -InputRef $ModelRef
$root = if ($ModelsRoot) { $ModelsRoot } else { Get-DefaultModelsRoot }

$manifestsDir = Join-Path $root ("manifests/registry.ollama.ai/{0}" -f $model.ModelPath)
$blobsDir = Join-Path $root 'blobs'
Ensure-Dir -Path $manifestsDir
Ensure-Dir -Path $blobsDir

$manifestUrl = "https://registry.ollama.ai/v2/$($model.ModelPath)/manifests/$($model.Tag)"
$blobBaseUrl = "https://registry.ollama.ai/v2/$($model.ModelPath)/blobs"
$manifestOut = Join-Path $manifestsDir $model.Tag

Write-Host "Model reference : $ModelRef"
Write-Host "Manifest URL    : $manifestUrl"
Write-Host "Models root     : $root"

$client = New-HttpClient
try {
    Write-Host 'Fetching manifest...'
    $manifestJson = Download-Text -Client $client -Url $manifestUrl
    $manifest = $manifestJson | ConvertFrom-Json

    if (-not $SkipManifest) {
        if ($Force -or -not (Test-Path -LiteralPath $manifestOut)) {
            [System.IO.File]::WriteAllText($manifestOut, $manifestJson, [System.Text.Encoding]::UTF8)
            Write-Host "Saved manifest   : $manifestOut"
        }
        else {
            Write-Host "Manifest exists  : $manifestOut (use -Force to overwrite)"
        }
    }

    $blobEntries = @(
        [PSCustomObject]@{ Digest = $manifest.config.digest; Size = [long]$manifest.config.size }
        $manifest.layers | ForEach-Object {
            [PSCustomObject]@{ Digest = $_.digest; Size = [long]$_.size }
        }
    )

    $jobs = [System.Collections.Generic.List[System.Management.Automation.Job]]::new()
    $completed = 0

    foreach ($entry in $blobEntries) {
        $fileName = $entry.Digest.Replace(':', '-')
        $outFile = Join-Path $blobsDir $fileName

        if (-not $Force -and (Test-Path -LiteralPath $outFile)) {
            $existing = (Get-Item -LiteralPath $outFile).Length
            if ($existing -eq $entry.Size) {
                $completed++
                Write-Host ("[{0}/{1}] Skip {2} (already complete)" -f $completed, $blobEntries.Count, $fileName)
                continue
            }
        }

        while ($jobs.Count -ge $MaxConcurrency) {
            $doneJob = Wait-Job -Job $jobs -Any
            Receive-Job -Job $doneJob | Write-Host
            if ($doneJob.State -ne 'Completed') {
                throw "Blob download job failed: $($doneJob.ChildJobs[0].JobStateInfo.Reason)"
            }
            [void]$jobs.Remove($doneJob)
            Remove-Job -Job $doneJob -Force
            $completed++
            Write-Host ("[{0}/{1}] Done" -f $completed, $blobEntries.Count)
        }

        $job = Start-Job -ScriptBlock {
                param($url, $path, $expectedSize)

                $http = [System.Net.Http.HttpClient]::new()
                $http.Timeout = [TimeSpan]::FromMinutes(30)
                $tmp = "$path.part"

                try {
                    $resp = $http.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                    if (-not $resp.IsSuccessStatusCode) {
                        throw "GET $url failed with HTTP $([int]$resp.StatusCode) $($resp.ReasonPhrase)"
                    }

                    $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    $out = [System.IO.File]::Open($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    try {
                        $in.CopyTo($out)
                    }
                    finally {
                        $out.Dispose()
                        $in.Dispose()
                        $resp.Dispose()
                        $http.Dispose()
                    }

                    $actual = (Get-Item -LiteralPath $tmp).Length
                    if ($actual -ne $expectedSize) {
                        throw "Size mismatch for $path. Expected $expectedSize, got $actual"
                    }

                    Move-Item -LiteralPath $tmp -Destination $path -Force
                    "Saved $path"
                }
                catch {
                    if (Test-Path -LiteralPath $tmp) {
                        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                    }
                    throw
                }
            } -ArgumentList @("$blobBaseUrl/$($entry.Digest)", $outFile, $entry.Size)
        [void]$jobs.Add($job)
    }

    while ($jobs.Count -gt 0) {
        $doneJob = Wait-Job -Job $jobs -Any
        Receive-Job -Job $doneJob | Write-Host
        if ($doneJob.State -ne 'Completed') {
            throw "Blob download job failed: $($doneJob.ChildJobs[0].JobStateInfo.Reason)"
        }
        [void]$jobs.Remove($doneJob)
        Remove-Job -Job $doneJob -Force
        $completed++
        Write-Host ("[{0}/{1}] Done" -f $completed, $blobEntries.Count)
    }

    Write-Host "Finished. Downloaded/verified $($blobEntries.Count) blobs."
}
finally {
    $client.Dispose()
}

param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [string]$LogDirectory = '',

    [int64]$MaxLogBytes = 5MB,

    [ValidateRange(1, 365)]
    [int]$RetentionDays = 5,

    [ValidateRange(30, 3600)]
    [int]$CommandTimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'Never'

$mutex = $null
$hasMutex = $false

$excludedDirectoryNames = @(
    '.git',
    '.hg',
    '.svn',
    '.vs',
    '.vscode',
    'node_modules',
    'vendor',
    'vendors',
    'packages',
    'bower_components',
    'bin',
    'obj',
    'build',
    'dist',
    'out',
    'target',
    'coverage',
    '.next',
    '.nuxt',
    '.angular',
    '.cache',
    '.gradle',
    '.idea',
    '__pycache__'
)

function Initialize-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int64]$LimitBytes
    )

    $logDirectory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }

    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Length -gt $LimitBytes)) {
        $archivePath = "$Path.1"
        if (Test-Path -LiteralPath $archivePath) {
            Remove-Item -LiteralPath $archivePath -Force
        }
        Move-Item -LiteralPath $Path -Destination $archivePath -Force
    }
}

function Remove-OldLogs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [int]$DaysToKeep
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return
    }

    $cutoff = (Get-Date).Date.AddDays(-1 * ($DaysToKeep - 1))
    Get-ChildItem -LiteralPath $Directory -File -Filter 'autoff-*.log*' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-RepoLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [Parameter(Mandatory = $true)]
        [string]$Branch,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [string]$Message = ''
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    $safeMessage = $Message -replace "[\r\n]+", ' '
    $line = "$timestamp`t$RepoPath`t$Branch`t$Action"
    if ($safeMessage) {
        $line = "$line`t$safeMessage"
    }

    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    function Quote-Argument {
        param([Parameter(Mandatory = $true)][string]$Value)

        if ($Value -notmatch '[\s"]') {
            return $Value
        }

        '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }

    $process = $null

    function Stop-ProcessTree {
        param([Parameter(Mandatory = $true)][int]$ProcessId)

        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue
        foreach ($child in $children) {
            Stop-ProcessTree -ProcessId $child.ProcessId
        }

        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }

    try {
        $fullArguments = @('-C', $RepoPath) + $Arguments
        $argumentLine = ($fullArguments | ForEach-Object { Quote-Argument -Value $_ }) -join ' '
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = 'git.exe'
        $startInfo.Arguments = $argumentLine
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        $null = $process.Start()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                Stop-ProcessTree -ProcessId $process.Id
                $process.WaitForExit()
            } catch {
            }

            return [pscustomobject]@{
                ExitCode = 124
                Output = "git command timed out after $TimeoutSeconds seconds: git $argumentLine"
            }
        }

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = (($stdout, $stderr) -join ' ').Trim()
        }
    } finally {
        if ($process) {
            $process.Dispose()
        }
    }
}

function Find-GitRepositories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $root = Get-Item -LiteralPath $Path
    $repositories = New-Object System.Collections.Generic.List[string]

    function Visit-Directory {
        param([Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$Directory)

        $gitDirectory = Join-Path $Directory.FullName '.git'
        if (Test-Path -LiteralPath $gitDirectory -PathType Container) {
            $repositories.Add($Directory.FullName)
        }

        try {
            $children = Get-ChildItem -LiteralPath $Directory.FullName -Directory -Force -ErrorAction Stop
        } catch {
            return
        }

        foreach ($child in $children) {
            if ($excludedDirectoryNames -contains $child.Name) {
                continue
            }

            Visit-Directory -Directory $child
        }
    }

    Visit-Directory -Directory $root
    $repositories | Sort-Object -Unique
}

function Convert-GitPathToComparablePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    ($Path -replace '\\', '/').TrimEnd('/')
}

function Test-PathOverlap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FirstPath,

        [Parameter(Mandatory = $true)]
        [string]$SecondPath
    )

    $first = Convert-GitPathToComparablePath -Path $FirstPath
    $second = Convert-GitPathToComparablePath -Path $SecondPath

    if (-not $first -or -not $second) {
        return $false
    }

    $first.Equals($second, [System.StringComparison]::Ordinal) -or
        $first.StartsWith("$second/", [System.StringComparison]::Ordinal) -or
        $second.StartsWith("$first/", [System.StringComparison]::Ordinal)
}

function Get-PorcelainStatusEntries {
    param([string]$StatusOutput)

    if (-not $StatusOutput) {
        return @()
    }

    $rawEntries = $StatusOutput -split "`0" | Where-Object { $_ }
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($rawEntry in $rawEntries) {
        if ($rawEntry.Length -lt 3) {
            continue
        }

        $statusCode = $rawEntry.Substring(0, 2)
        $path = $rawEntry.Substring(3)
        if ($statusCode.StartsWith('R') -or $statusCode.StartsWith('C')) {
            $pathParts = $path -split "`t"
            $path = $pathParts[-1]
        }

        $entries.Add([pscustomobject]@{
            StatusCode = $statusCode
            Path = $path
        })
    }

    $entries
}

function Test-CanFastForwardWithStatusEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$StatusEntries,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    if ($StatusEntries.Count -eq 0) {
        return $true
    }

    $trackedChanges = @($StatusEntries | Where-Object { $_.StatusCode -ne '??' })
    if ($trackedChanges.Count -gt 0) {
        return $false
    }

    $untrackedPaths = @($StatusEntries | ForEach-Object { $_.Path })
    if ($untrackedPaths.Count -eq 0) {
        return $true
    }

    $changedPathsResult = Invoke-Git -RepoPath $RepoPath -Arguments @('diff', '--name-only', '-z', 'HEAD..@{u}') -TimeoutSeconds $TimeoutSeconds
    if ($changedPathsResult.ExitCode -ne 0) {
        return $false
    }

    $changedPaths = @($changedPathsResult.Output -split "`0" | Where-Object { $_ })
    foreach ($untrackedPath in $untrackedPaths) {
        foreach ($changedPath in $changedPaths) {
            if (Test-PathOverlap -FirstPath $untrackedPath -SecondPath $changedPath) {
                return $false
            }
        }
    }

    return $true
}

try {
    $rootBytes = [System.Text.Encoding]::UTF8.GetBytes($RootPath.ToLowerInvariant())
    $rootHashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash($rootBytes)
    $rootHash = ([System.BitConverter]::ToString($rootHashBytes)).Replace('-', '')
    $mutex = New-Object System.Threading.Mutex($false, "Local\GitAutoFF-$rootHash")
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        exit 0
    }

    if ([System.String]::IsNullOrWhiteSpace($LogDirectory)) {
        $LogDirectory = Join-Path $RootPath 'GitAutoFF\logs'
    }

    $LogPath = Join-Path $LogDirectory ("autoff-{0}.log" -f (Get-Date).ToString('yyyy-MM-dd'))
    Initialize-Log -Path $LogPath -LimitBytes $MaxLogBytes
    Remove-OldLogs -Directory $LogDirectory -DaysToKeep $RetentionDays

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        Write-RepoLog -Path $LogPath -RepoPath $RootPath -Branch '-' -Action 'error' -Message 'Root path does not exist or is not a directory.'
        exit 0
    }

    $repos = Find-GitRepositories -Path $RootPath

    foreach ($repo in $repos) {
        $branch = '-'

        try {
            $branchResult = Invoke-Git -RepoPath $repo -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD') -TimeoutSeconds $CommandTimeoutSeconds
            if ($branchResult.ExitCode -eq 0 -and $branchResult.Output) {
                $branch = $branchResult.Output
            } else {
                $branch = '(detached)'
            }

            $fetchResult = Invoke-Git -RepoPath $repo -Arguments @('fetch', '--all', '--prune', '--quiet') -TimeoutSeconds $CommandTimeoutSeconds
            if ($fetchResult.ExitCode -ne 0) {
                Write-RepoLog -Path $LogPath -RepoPath $repo -Branch $branch -Action 'error' -Message $fetchResult.Output
                continue
            }

            $upstreamResult = Invoke-Git -RepoPath $repo -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}') -TimeoutSeconds $CommandTimeoutSeconds
            if ($upstreamResult.ExitCode -ne 0 -or -not $upstreamResult.Output) {
                Write-RepoLog -Path $LogPath -RepoPath $repo -Branch $branch -Action 'skipped-no-upstream'
                continue
            }

            $statusResult = Invoke-Git -RepoPath $repo -Arguments @('status', '--porcelain=v1', '-z', '--untracked-files=all') -TimeoutSeconds $CommandTimeoutSeconds
            if ($statusResult.ExitCode -ne 0) {
                Write-RepoLog -Path $LogPath -RepoPath $repo -Branch $branch -Action 'error' -Message $statusResult.Output
                continue
            }

            $statusEntries = @(Get-PorcelainStatusEntries -StatusOutput $statusResult.Output)
            if (-not (Test-CanFastForwardWithStatusEntries -RepoPath $repo -StatusEntries $statusEntries -TimeoutSeconds $CommandTimeoutSeconds)) {
                Write-RepoLog -Path $LogPath -RepoPath $repo -Branch $branch -Action 'skipped-dirty'
                continue
            }

            $headResult = Invoke-Git -RepoPath $repo -Arguments @('rev-parse', 'HEAD') -TimeoutSeconds $CommandTimeoutSeconds
            $upstreamHeadResult = Invoke-Git -RepoPath $repo -Arguments @('rev-parse', '@{u}') -TimeoutSeconds $CommandTimeoutSeconds
            if ($headResult.ExitCode -ne 0 -or $upstreamHeadResult.ExitCode -ne 0) {
                Write-RepoLog -Path $LogPath -RepoPath $repo -Branch $branch -Action 'error' -Message (($headResult.Output, $upstreamHeadResult.Output) -join ' ')
                continue
            }

            if ($headResult.Output -eq $upstreamHeadResult.Output) {
                Write-RepoLog -Path $LogPath -RepoPath $repo -Branch $branch -Action 'fetched'
                continue
            }

            $ancestorResult = Invoke-Git -RepoPath $repo -Arguments @('merge-base', '--is-ancestor', 'HEAD', '@{u}') -TimeoutSeconds $CommandTimeoutSeconds
            if ($ancestorResult.ExitCode -eq 0) {
                $mergeResult = Invoke-Git -RepoPath $repo -Arguments @('merge', '--ff-only', '--quiet') -TimeoutSeconds $CommandTimeoutSeconds
                if ($mergeResult.ExitCode -eq 0) {
                    Write-RepoLog -Path $LogPath -RepoPath $repo -Branch $branch -Action 'fast-forwarded'
                } else {
                    Write-RepoLog -Path $LogPath -RepoPath $repo -Branch $branch -Action 'error' -Message $mergeResult.Output
                }
            } elseif ($ancestorResult.ExitCode -eq 1) {
                Write-RepoLog -Path $LogPath -RepoPath $repo -Branch $branch -Action 'skipped-diverged'
            } else {
                Write-RepoLog -Path $LogPath -RepoPath $repo -Branch $branch -Action 'error' -Message $ancestorResult.Output
            }
        } catch {
            Write-RepoLog -Path $LogPath -RepoPath $repo -Branch $branch -Action 'error' -Message $_.Exception.Message
        }
    }
} catch {
    try {
        if (-not $LogPath) {
            if ([System.String]::IsNullOrWhiteSpace($LogDirectory)) {
                $LogDirectory = Join-Path $RootPath 'GitAutoFF\logs'
            }
            $LogPath = Join-Path $LogDirectory ("autoff-{0}.log" -f (Get-Date).ToString('yyyy-MM-dd'))
        }
        Initialize-Log -Path $LogPath -LimitBytes $MaxLogBytes
        Write-RepoLog -Path $LogPath -RepoPath $RootPath -Branch '-' -Action 'error' -Message $_.Exception.Message
    } catch {
    }
} finally {
    if ($hasMutex -and $mutex) {
        $mutex.ReleaseMutex()
    }
    if ($mutex) {
        $mutex.Dispose()
    }
}

exit 0

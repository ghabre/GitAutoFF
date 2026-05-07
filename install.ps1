param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 525600)]
    [int]$IntervalMinutes,

    [string]$TaskName = 'GitAutoFastForward',

    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'GitAutoFF'),

    [switch]$RunWhetherLoggedOnOrNotWithPassword
)

$ErrorActionPreference = 'Stop'

$sourceWorker = Join-Path $PSScriptRoot 'autoff.ps1'
$sourceLauncher = Join-Path $PSScriptRoot 'run-hidden.vbs'
$targetWorker = Join-Path $InstallDirectory 'autoff.ps1'
$targetUninstaller = Join-Path $InstallDirectory 'uninstall.ps1'
$targetLauncher = Join-Path $InstallDirectory 'run-hidden.vbs'
$logDirectory = Join-Path $RootPath 'GitAutoFF\logs'

if (-not (Test-Path -LiteralPath $sourceWorker -PathType Leaf)) {
    throw "Worker script not found: $sourceWorker"
}

if (-not (Test-Path -LiteralPath $sourceLauncher -PathType Leaf)) {
    throw "Hidden launcher script not found: $sourceLauncher"
}

if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
    throw "Root path does not exist or is not a directory: $RootPath"
}

New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
Copy-Item -LiteralPath $sourceWorker -Destination $targetWorker -Force
Copy-Item -LiteralPath $sourceLauncher -Destination $targetLauncher -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'uninstall.ps1') -Destination $targetUninstaller -Force

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$escapedWorker = $targetWorker.Replace('"', '\"')
$escapedRoot = $RootPath.Replace('"', '\"')
$escapedLauncher = $targetLauncher.Replace('"', '\"')
if ($RunWhetherLoggedOnOrNotWithPassword) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$escapedWorker`" -RootPath `"$escapedRoot`" -RetentionDays 5 -CommandTimeoutSeconds 300"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
} else {
    $arguments = "//B //Nologo `"$escapedLauncher`" `"$escapedWorker`" `"$escapedRoot`" 5 300"
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $arguments
}
$interval = New-TimeSpan -Minutes $IntervalMinutes
$startupBoundary = (Get-Date).AddMinutes($IntervalMinutes).ToString('s')
$intervalTrigger = New-ScheduledTaskTrigger -Once -At $startupBoundary -RepetitionInterval $interval
$currentUser = (& whoami).Trim()
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$principal = if ($RunWhetherLoggedOnOrNotWithPassword) {
    New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Password -RunLevel Limited
} else {
    New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
}
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -MultipleInstances IgnoreNew
if ($RunWhetherLoggedOnOrNotWithPassword) {
    $credential = Get-Credential -UserName $currentUser -Message "Enter the Windows password for $currentUser so Task Scheduler can run GitAutoFastForward when you are logged off."
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password)
    try {
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        Register-ScheduledTask `
            -TaskName $TaskName `
            -Action $action `
            -Trigger @($intervalTrigger, $logonTrigger) `
            -Settings $settings `
            -User $currentUser `
            -Password $plainPassword `
            -Description "Automatically fetches Git repositories under $RootPath and fast-forwards clean current branches." `
            -Force | Out-Null
    } finally {
        if ($bstr -ne [System.IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
} else {
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger @($intervalTrigger, $logonTrigger) `
        -Settings $settings `
        -Principal $principal `
        -Description "Automatically fetches Git repositories under $RootPath and fast-forwards clean current branches." `
        -Force | Out-Null
}

Write-Host "Installed worker: $targetWorker"
Write-Host "Installed hidden launcher: $targetLauncher"
Write-Host "Registered task: $TaskName"
Write-Host "Root path: $RootPath"
Write-Host "Interval: every $IntervalMinutes minutes"
Write-Host "Logon mode: $($principal.LogonType)"
Write-Host "Log directory: $logDirectory"
Write-Host "Log files: autoff-yyyy-MM-dd.log, retaining the last 5 days"
Write-Host "Uninstall: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$targetUninstaller`""

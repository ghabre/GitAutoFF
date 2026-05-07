param(
    [string]$TaskName = 'GitAutoFastForward',

    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'GitAutoFF'),

    [switch]$RemoveInstallFolder
)

$ErrorActionPreference = 'Stop'

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed task: $TaskName"
} else {
    Write-Host "Task not found: $TaskName"
}

if ($RemoveInstallFolder) {
    $resolvedInstallDirectory = Resolve-Path -LiteralPath $InstallDirectory -ErrorAction SilentlyContinue
    if ($resolvedInstallDirectory) {
        $localAppData = [System.IO.Path]::GetFullPath($env:LOCALAPPDATA)
        $installPath = [System.IO.Path]::GetFullPath($resolvedInstallDirectory.Path)

        if ($installPath.StartsWith($localAppData, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $installPath -Recurse -Force
            Write-Host "Removed install folder: $installPath"
        } else {
            throw "Refusing to remove install folder outside LOCALAPPDATA: $installPath"
        }
    }
}

# GitAutoFF

`GitAutoFF` keeps Git repositories under a root folder up to date without prompting and without unsafe branch changes.

It discovers repositories recursively by finding `.git` directories, skips common dependency/build folders, runs `git fetch --all --prune --quiet`, and fast-forwards only the currently checked-out branch when:

- the branch has an upstream
- `HEAD` is an ancestor of `@{u}`
- there are no staged or unstaged tracked changes
- any untracked files do not overlap paths changed by the upstream fast-forward

It never rebases, never creates merge commits, never prompts for credentials, and exits `0` even when individual repos fail.

## Files

- `autoff.ps1`: worker script that discovers repos, fetches, fast-forwards eligible clean branches, and logs each repo.
- `install.ps1`: copies `autoff.ps1` and `uninstall.ps1` to `%LOCALAPPDATA%\GitAutoFF`, then registers the `GitAutoFastForward` Scheduled Task.
- `run-hidden.vbs`: hidden launcher used by the default interactive Scheduled Task so no console window is shown.
- `uninstall.ps1`: removes the Scheduled Task and can optionally remove the installed folder.

## Install

From this folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -RootPath "C:\G\Code" -IntervalMinutes 180
```

Use your own root path and interval if needed. Examples:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -RootPath "D:\Repos" -IntervalMinutes 30
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -RootPath "C:\Work" -IntervalMinutes 60
```

The installer is idempotent. Re-running it replaces the existing scheduled task cleanly.

## Run Once Manually

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\GitAutoFF\autoff.ps1" -RootPath "C:\G\Code"
```

The worker derives the log folder from `-RootPath` when `-LogDirectory` is omitted. For `-RootPath "C:\G\Code"`, logs go to `C:\G\Code\GitAutoFF\logs`.

## Logs

Log folder:

```powershell
C:\G\Code\GitAutoFF\logs
```

Log files are date-stamped:

```text
autoff-yyyy-MM-dd.log
```

The worker keeps the last 5 days of `autoff-*.log*` files.

Show the latest lines:

```powershell
Get-Content -LiteralPath ("C:\G\Code\GitAutoFF\logs\autoff-{0}.log" -f (Get-Date).ToString('yyyy-MM-dd')) -Tail 50
```

Each line contains:

```text
timestamp    repo path    branch    action    optional message
```

Actions include:

- `fetched`
- `fast-forwarded`
- `skipped-dirty`
- `skipped-no-upstream`
- `skipped-diverged`
- `error`

If a daily log exceeds about 5 MB, it rotates to `.log.1`.

## Verify Task

```powershell
Get-ScheduledTask -TaskName GitAutoFastForward | Get-ScheduledTaskInfo
Get-ScheduledTask -TaskName GitAutoFastForward | Format-List TaskName,State,TaskPath
(Get-ScheduledTask -TaskName GitAutoFastForward).Triggers
```

## Uninstall

Remove the task only:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\GitAutoFF\uninstall.ps1"
```

Remove the task and installed `%LOCALAPPDATA%\GitAutoFF` folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\GitAutoFF\uninstall.ps1" -RemoveInstallFolder
```

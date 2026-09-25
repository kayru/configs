# Dot-sourced from $PROFILE (Windows PowerShell 5.1 and PowerShell 7)

if (Get-Module -ListAvailable -Name PSReadLine) {
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
    Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineOption -HistoryNoDuplicates
}

function l { Get-ChildItem @args }
function la { Get-ChildItem -Force @args }
function ll { Get-ChildItem -Force @args | Format-Table -AutoSize }

function prompt {
    # git below would otherwise clobber the user's last exit code
    $savedExitCode = $global:LASTEXITCODE
    $esc = [char]27
    $branch = $null
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $branch = git symbolic-ref --short -q HEAD 2> $null
    }
    $global:LASTEXITCODE = $savedExitCode
    $location = $ExecutionContext.SessionState.Path.CurrentLocation.Path
    $gitPart = if ($branch) { " $esc[36m($branch)$esc[0m" } else { '' }
    "$esc[33m$location$esc[0m$gitPart`n> "
}

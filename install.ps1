# Windows counterpart of install.sh: plans all changes, shows them, then applies the ones you accept.
# Safe to re-run. Covers PowerShell 5.1/7, native vim and Git Bash; use install.sh inside WSL.
#
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-Yes] [-DryRun] [-NoDeps]
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$NoDeps
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$Repo = $PSScriptRoot
# git, vim and Git Bash all prefer %HOME% over %USERPROFILE% when it is set
$UserHome = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

if ($Repo -match '\s') {
    [Console]::Error.WriteLine("error: repo path must not contain whitespace: $Repo")
    exit 1
}

# ---- path forms

function Get-FullPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-SamePath([string]$A, [string]$B) {
    $A = $A -replace '^\\\\\?\\|^\\\?\?\\', ''
    return [string]::Equals((Get-FullPath $A), (Get-FullPath $B), [StringComparison]::OrdinalIgnoreCase)
}

# Remainder of $Path under $Base with forward slashes, or $null when outside it
function Get-RelativeUnder([string]$Path, [string]$Base) {
    $full = Get-FullPath $Path
    $baseFull = Get-FullPath $Base
    if ($full.StartsWith($baseFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($baseFull.Length + 1).Replace('\', '/')
    }
    return $null
}

# For git and vim: ~/x/y under home, else C:/x/y
function ConvertTo-GitPath([string]$Path) {
    $rel = Get-RelativeUnder $Path $UserHome
    if ($rel) {
        return "~/$rel"
    }
    return (Get-FullPath $Path).Replace('\', '/')
}

# For Git Bash: ~/x/y under home, else /c/x/y
function ConvertTo-BashPath([string]$Path) {
    $rel = Get-RelativeUnder $Path $UserHome
    if ($rel) {
        return "~/$rel"
    }
    $full = Get-FullPath $Path
    return '/' + $full.Substring(0, 1).ToLowerInvariant() + $full.Substring(2).Replace('\', '/')
}

function Format-Display([string]$Path) {
    $rel = Get-RelativeUnder $Path $UserHome
    if ($rel) {
        return '~\' + $rel.Replace('/', '\')
    }
    return $Path
}

# ---- native commands

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Stdout only; check $LASTEXITCODE after. Under 'Stop', 5.1 turns redirected stderr into terminating errors.
function Invoke-Quiet([string]$Exe, [string[]]$Arguments) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments 2> $null
    } finally {
        $ErrorActionPreference = $saved
    }
}

function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Exe $($Arguments -join ' ') exited with $LASTEXITCODE"
    }
}

# ---- plan storage: function name + args, since GetNewClosure blocks can't see script functions

$Steps = New-Object System.Collections.Generic.List[object]
$DoneItems = New-Object System.Collections.Generic.List[string]
$Notes = New-Object System.Collections.Generic.List[string]

function Add-Step([string]$Desc, [string]$Fn, [object[]]$FnArgs = @()) {
    $Steps.Add([pscustomobject]@{ Desc = $Desc; Fn = $Fn; FnArgs = $FnArgs })
}

# ---- actions (only run for accepted steps)

function Test-FileHasLine([string]$File, [string]$Line) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
        return $false
    }
    foreach ($existing in [IO.File]::ReadAllLines($File)) {
        if ($existing -ceq $Line) {
            return $true
        }
    }
    return $false
}

function New-ParentDir([string]$Path) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# LF and no BOM: Git Bash can't parse CRLF or a BOM in .bashrc
function Add-LineToFile([string]$File, [string]$Line) {
    if (Test-FileHasLine $File $Line) {
        return
    }
    New-ParentDir $File
    $prefix = ''
    if ((Test-Path -LiteralPath $File) -and (Get-Item -LiteralPath $File).Length -gt 0) {
        $prefix = "`n"
    }
    [IO.File]::AppendAllText($File, "$prefix$Line`n", $Utf8NoBom)
}

function New-Junction([string]$Target, [string]$Link) {
    New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
}

function Copy-File([string]$Src, [string]$Dst) {
    New-ParentDir $Dst
    Copy-Item -LiteralPath $Src -Destination $Dst -Force
}

function Add-GitInclude([string]$File, [string]$IncludePath) {
    $existing = ''
    if (Test-Path -LiteralPath $File) {
        $existing = [IO.File]::ReadAllText($File)
    }
    [IO.File]::WriteAllText($File, "[include]`n`tpath = $IncludePath`n" + $existing, $Utf8NoBom)
}

function Update-Submodules {
    Invoke-Checked git @('-C', $Repo, 'submodule', 'sync', '--quiet')
    Invoke-Checked git @('-C', $Repo, 'submodule', 'update', '--init', '--quiet')
}

function Install-WingetPackages([string[]]$Ids) {
    foreach ($id in $Ids) {
        Invoke-Checked winget @('install', '--id', $id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    }
    # Installers update the registry PATH, not this process's
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Set-UserExecutionPolicy([string]$Exe) {
    Invoke-Checked $Exe @('-NoProfile', '-NonInteractive', '-Command', 'Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force')
}

# ---- planning helpers (read-only)

function Register-Line([string]$File, [string]$Line) {
    if (Test-FileHasLine $File $Line) {
        $DoneItems.Add("$(Format-Display $File) has: $Line")
    } else {
        Add-Step "Append to $(Format-Display $File): $Line" 'Add-LineToFile' @($File, $Line)
    }
}

function Register-Junction([string]$Target, [string]$Link) {
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if (-not $item) {
        Add-Step "Junction $(Format-Display $Link) -> $(Format-Display $Target)" 'New-Junction' @($Target, $Link)
        return
    }
    $linkTarget = @($item.Target) | Select-Object -First 1
    if ($item.LinkType -in 'Junction', 'SymbolicLink' -and $linkTarget -and (Test-SamePath $linkTarget $Target)) {
        $DoneItems.Add("$(Format-Display $Link) -> $(Format-Display $Target)")
    } else {
        $Notes.Add("$(Format-Display $Link) exists and is not a link to $(Format-Display $Target); move it aside and re-run")
    }
}

function Register-Copy([string]$Src, [string]$Dst) {
    if (-not (Test-Path -LiteralPath $Dst)) {
        Add-Step "Copy $(Format-Display $Src) -> $(Format-Display $Dst)" 'Copy-File' @($Src, $Dst)
    } elseif ((Get-FileHash -LiteralPath $Src).Hash -eq (Get-FileHash -LiteralPath $Dst).Hash) {
        $DoneItems.Add("$(Format-Display $Dst) up to date")
    } else {
        Add-Step "Overwrite $(Format-Display $Dst) with $(Format-Display $Src)" 'Copy-File' @($Src, $Dst)
    }
}

# ---- plan

$Packages = @(
    @{ Id = 'Git.Git' },
    @{ Id = 'Kitware.CMake' },
    @{ Id = 'Ninja-build.Ninja' },
    # Any installed 3.x satisfies it
    @{ Id = 'Python.Python.3.14'; Match = 'Python.Python.3' },
    @{ Id = 'BurntSushi.ripgrep.MSVC' },
    @{ Id = 'sharkdp.fd' },
    @{ Id = 'jqlang.jq' },
    @{ Id = 'junegunn.fzf' },
    @{ Id = 'ajeetdsouza.zoxide' },
    @{ Id = 'vim.vim' }
)

$GitPlanned = $false
if ($NoDeps) {
    $Notes.Add('packages not checked (-NoDeps)')
} elseif (-not (Test-Command winget)) {
    $Notes.Add('packages not installed: winget not found (install App Installer from the Microsoft Store)')
} else {
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($pkg in $Packages) {
        if ($pkg.ContainsKey('Match')) {
            $query = @('list', '--id', $pkg.Match)
        } else {
            $query = @('list', '--id', $pkg.Id, '--exact')
        }
        Invoke-Quiet winget ($query + @('--accept-source-agreements', '--disable-interactivity')) | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $missing.Add($pkg.Id)
        }
    }
    if ($missing.Count -eq 0) {
        $DoneItems.Add("packages: $(($Packages | ForEach-Object { $_.Id }) -join ' ')")
    } else {
        Add-Step "winget install $($missing -join ' ')" 'Install-WingetPackages' @(, [string[]]$missing)
        $GitPlanned = $missing.Contains('Git.Git')
    }
}

# Default on Windows clients is Restricted, which blocks loading the profile
$PowerShells = @(
    @{ Exe = 'powershell.exe'; Name = 'Windows PowerShell'; ProfileDir = 'WindowsPowerShell' },
    @{ Exe = 'pwsh.exe'; Name = 'PowerShell 7'; ProfileDir = 'PowerShell' }
)
foreach ($ps in $PowerShells) {
    if (-not (Test-Command $ps.Exe)) {
        continue
    }
    $policy = (Invoke-Quiet $ps.Exe @('-NoProfile', '-NonInteractive', '-Command', 'Get-ExecutionPolicy') | Select-Object -Last 1)
    $policy = "$policy".Trim()
    if ($policy -in 'Restricted', 'AllSigned', 'Undefined') {
        Add-Step "$($ps.Name): Set-ExecutionPolicy -Scope CurrentUser RemoteSigned (currently $policy)" 'Set-UserExecutionPolicy' @($ps.Exe)
    } else {
        $DoneItems.Add("$($ps.Name) execution policy is $policy")
    }
}

$ProfileScript = Join-Path $Repo 'powershell\profile.ps1'
$profileRel = Get-RelativeUnder $ProfileScript $env:USERPROFILE
if ($profileRel) {
    # $HOME is %USERPROFILE% in PowerShell
    $ProfileLine = ". `"`$HOME\$($profileRel.Replace('/', '\'))`""
} else {
    $ProfileLine = ". '$ProfileScript'"
}
$Documents = [Environment]::GetFolderPath('MyDocuments')
foreach ($ps in $PowerShells) {
    if (Test-Command $ps.Exe) {
        Register-Line (Join-Path $Documents "$($ps.ProfileDir)\Microsoft.PowerShell_profile.ps1") $ProfileLine
    } else {
        $Notes.Add("$($ps.Name) not installed; its profile is not set up")
    }
}

$GitConfig = Join-Path $UserHome '.gitconfig'
$GitInclude = ConvertTo-GitPath (Join-Path $Repo 'git\gitconfig')
$includes = @()
if (Test-Command git) {
    $includes = @(Invoke-Quiet git @('config', '--global', '--get-all', 'include.path'))
}
if ($includes -contains $GitInclude) {
    $DoneItems.Add("~\.gitconfig includes $GitInclude")
} else {
    # Prepended so settings later in ~/.gitconfig override the shared ones
    Add-Step "Prepend to ~\.gitconfig: [include] path = $GitInclude" 'Add-GitInclude' @($GitConfig, $GitInclude)
}

$submodulesReady = Test-Command git
if ($submodulesReady) {
    $status = @(Invoke-Quiet git @('-C', $Repo, 'submodule', 'status'))
    if ($LASTEXITCODE -ne 0 -or @($status | Where-Object { $_ -match '^[-+U]' }).Count -gt 0) {
        $submodulesReady = $false
    }
    $urls = @(Invoke-Quiet git @('-C', $Repo, 'config', '-f', '.gitmodules', '--get-regexp', '^submodule\..*\.url$'))
    foreach ($entry in $urls) {
        $key, $url = $entry -split ' ', 2
        $configured = Invoke-Quiet git @('-C', $Repo, 'config', '--get', $key)
        if ("$configured" -ne $url) {
            $submodulesReady = $false
        }
    }
}
if ($submodulesReady) {
    $DoneItems.Add('vim plugin submodules checked out')
} else {
    Add-Step "Check out vim plugin submodules in $(Format-Display $Repo) (git submodule sync + update --init)" 'Update-Submodules'
}

$VimDir = Join-Path $Repo 'vim'
# Native vim reads ~/_vimrc and ~/vimfiles; Git Bash's vim reads ~/.vimrc and ~/.vim
Register-Junction $VimDir (Join-Path $UserHome 'vimfiles')
Register-Line (Join-Path $UserHome '_vimrc') 'source ~/vimfiles/kayru.vim'

$GitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
if ((Test-Path -LiteralPath $GitBash) -or $GitPlanned) {
    Register-Junction $VimDir (Join-Path $UserHome '.vim')
    Register-Line (Join-Path $UserHome '.vimrc') 'source ~/.vim/kayru.vim'
    $bashRc = Join-Path $UserHome '.bashrc'
    Register-Line $bashRc "source $(ConvertTo-BashPath (Join-Path $Repo 'bash\kayru_common.sh'))"
    Register-Line $bashRc "source $(ConvertTo-BashPath (Join-Path $Repo 'bash\dir_colors.sh'))"
    Register-Copy (Join-Path $Repo '.minttyrc') (Join-Path $UserHome '.minttyrc')
} else {
    $Notes.Add('Git Bash not installed; its config is not set up')
}

# ---- show plan

Write-Host 'Platform: windows'
if ($DoneItems.Count -gt 0) {
    Write-Host ''
    Write-Host 'Already done:'
    foreach ($item in $DoneItems) {
        Write-Host "  $item"
    }
}
if ($Notes.Count -gt 0) {
    Write-Host ''
    Write-Host 'Notes:'
    foreach ($item in $Notes) {
        Write-Host "  $item"
    }
}
Write-Host ''
if ($Steps.Count -eq 0) {
    Write-Host 'Nothing to do.'
    exit 0
}
Write-Host 'Planned changes:'
for ($i = 0; $i -lt $Steps.Count; $i++) {
    Write-Host ('  {0,2}. {1}' -f ($i + 1), $Steps[$i].Desc)
}
Write-Host ''

if ($DryRun) {
    exit 0
}

# ---- confirm

$Mode = if ($Yes) { 'all' } else { 'ask' }
if ($Mode -eq 'ask') {
    if ([Console]::IsInputRedirected) {
        [Console]::Error.WriteLine('error: stdin is not a terminal; pass -Yes to apply without prompting')
        exit 1
    }
    do {
        $answer = Read-Host 'Apply: [a]ll, [o]ne by one, [q]uit?'
    } until ($answer -in 'a', 'o', 'q')
    if ($answer -eq 'q') {
        exit 0
    }
    $Mode = if ($answer -eq 'a') { 'all' } else { 'each' }
}

# ---- apply

for ($i = 0; $i -lt $Steps.Count; $i++) {
    $step = $Steps[$i]
    if ($Mode -eq 'each') {
        do {
            $answer = Read-Host "$($i + 1). $($step.Desc)  [y]es, [n]o, [a]ll remaining, [q]uit?"
        } until ($answer -in 'y', 'n', 'a', 'q')
        if ($answer -eq 'q') {
            exit 0
        }
        if ($answer -eq 'n') {
            continue
        }
        if ($answer -eq 'a') {
            $Mode = 'all'
        }
    }
    Write-Host "==> $($step.Desc)"
    $fnArgs = $step.FnArgs
    try {
        & $step.Fn @fnArgs
    } catch {
        Write-Host "error: failed: $($step.Desc)" -ForegroundColor Red
        throw
    }
}
Write-Host 'Done.'

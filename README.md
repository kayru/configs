personal settings for various things

macOS, Ubuntu/Debian, Arch, SteamOS (and WSL):

    ./install.sh             # show planned changes, then apply all or one by one
    ./install.sh --dry-run   # show planned changes only
    ./install.sh --yes       # apply everything without prompting

`--no-deps` skips package installs, `--no-chsh` leaves the login shell alone.

Windows (PowerShell, native vim, Git Bash), from a PowerShell prompt:

    .\install.ps1 [-DryRun] [-Yes] [-NoDeps]

Windows PowerShell 5.1 blocks scripts by default (`Restricted`). The first time, run
`powershell -ExecutionPolicy Bypass -File install.ps1`; it offers to set `RemoteSigned` for
the current user, after which `.\install.ps1` works. PowerShell 7 allows it out of the box.

Over SSH, Windows 11 refuses to follow links created by non-elevated processes
(RedirectionGuard), so `~\vimfiles` and winget's command links only resolve in desktop sessions.

Both scripts are safe to re-run; already-applied items are listed and skipped.

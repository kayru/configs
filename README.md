personal settings for various things

macOS, Ubuntu/Debian, Arch, SteamOS (and WSL):

    ./install.sh             # show planned changes, then apply all or one by one
    ./install.sh --dry-run   # show planned changes only
    ./install.sh --yes       # apply everything without prompting

`--no-deps` skips package installs, `--no-chsh` leaves the login shell alone.

Windows (PowerShell, native vim, Git Bash):

    powershell -ExecutionPolicy Bypass -File install.ps1 [-DryRun] [-Yes] [-NoDeps]

Both scripts are safe to re-run; already-applied items are listed and skipped.

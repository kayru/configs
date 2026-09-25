# Useful bash stuff

UNAME=`uname`

# show current git branch (as per http://railstips.org/blog/archives/2009/02/02/bedazzle-your-bash-prompt-with-git-info/)

function parse_git_branch {
  ref=$(git symbolic-ref HEAD 2> /dev/null) || return
  echo "("${ref#refs/heads/}") "
}

# Over SSH, user@host gets a bold per-host colour (see zsh/zshrc, which must match)
HOST_STYLE="32"
if [ -n "$SSH_CONNECTION" ]; then
  if [ -z "$CONFIGS_HOST_COLOR" ]; then
    host_palette=(167 173 179 107 73 110 140 175)
    host_crc="$(printf %s "${HOSTNAME%%.*}" | cksum)"
    CONFIGS_HOST_COLOR=${host_palette[$(( ${host_crc%% *} % ${#host_palette[@]} ))]}
    unset host_palette host_crc
  fi
  HOST_STYLE="1;38;5;$CONFIGS_HOST_COLOR"
fi

if [ "$UNAME" == "FreeBSD" ]; then
	PS1="\u@\h \w $ "
else
	PS1="\[\e[${HOST_STYLE}m\]\u@\h\[\e[0m\] \[\e[33m\]\w\[\e[0m\] \$(parse_git_branch)\$ "
fi
unset HOST_STYLE

# make ls nicer

if [ "$UNAME" == "Darwin" -o "$UNAME" == "FreeBSD" ]; then
    export TERM=xterm-color
    alias ls='ls -G'
else
    alias ls='ls --color=auto'    
fi

alias l='ls -CF'
alias la='ls -A'
alias ll='ls -alF'

# completion stuff

# homebrew bash completion
if [ "$UNAME" == "Darwin" ] && [ -f `brew --prefix`/etc/bash_completion ]; then	
    . `brew --prefix`/etc/bash_completion	
else
	if [ -f /etc/bash_completion ] && ! shopt -oq posix; then
    . /etc/bash_completion
	fi
fi

# Auto-complete ssh commands
complete -W "$(echo $(grep -s '^ssh ' ~/.bash_history | sort -u | sed 's/^ssh //'))" ssh

# Auto-complete premake
complete -W "xcode4 vs2010 gmake clean" premake4

# fzf: Ctrl-R/Ctrl-T/Alt-C; zoxide: z
if command -v fzf > /dev/null; then
  # --bash needs fzf 0.48+; older Debian/Ubuntu packages ship the script instead
  if fzf --bash > /dev/null 2>&1; then
    eval "$(fzf --bash)"
  elif [ -f /usr/share/doc/fzf/examples/key-bindings.bash ]; then
    . /usr/share/doc/fzf/examples/key-bindings.bash
  fi
fi
if command -v zoxide > /dev/null; then
  eval "$(zoxide init bash)"
fi

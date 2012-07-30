# Useful bash stuff

UNAME=`uname`

# show current git branch (as per http://railstips.org/blog/archives/2009/02/02/bedazzle-your-bash-prompt-with-git-info/)

function parse_git_branch {
  ref=$(git symbolic-ref HEAD 2> /dev/null) || return
  echo "("${ref#refs/heads/}") "
}

if [ "$UNAME" == "FreeBSD" ]; then
	PS1="\u@\h \w $ "
else
	PS1="\[\e[32m\]\u@\h \[\e[33m\]\w\[\e[0m\] \$(parse_git_branch)\$ "
fi

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
complete -W "$(echo $(grep '^ssh ' ~/.bash_history | sort -u | sed 's/^ssh //'))" ssh

# Auto-complete premake
complete -W "xcode4 vs2010 gmake clean" premake4

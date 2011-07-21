# Useful bash stuff

#####################################################################
#####################################################################
#####################################################################

# If not running interactively, don't do anything
[[ "$-" != *i* ]] && return

# Setup SSH Agent

SSH_ENV="$HOME/.ssh/environment"

# start the ssh-agent
function start_agent {
    echo "Initializing new SSH agent..."
    # spawn ssh-agent
    ssh-agent | sed 's/^echo/#echo/' > "$SSH_ENV"
    echo succeeded
    chmod 600 "$SSH_ENV"
    . "$SSH_ENV" > /dev/null
    ssh-add
}

# test for identities
function test_identities {
    # test whether standard identities have been added to the agent already
    ssh-add -l | grep "The agent has no identities" > /dev/null
    if [ $? -eq 0 ]; then
        ssh-add
        # $SSH_AUTH_SOCK broken so we start a new proper agent
        if [ $? -eq 2 ];then
            start_agent
        fi
    fi
}

# check for running ssh-agent with proper $SSH_AGENT_PID
if [ -n "$SSH_AGENT_PID" ]; then
    ps -ef | grep "$SSH_AGENT_PID" | grep ssh-agent > /dev/null
    if [ $? -eq 0 ]; then
	test_identities
    fi
# if $SSH_AGENT_PID is not properly set, we might be able to load one from
# $SSH_ENV
else
    if [ -f "$SSH_ENV" ]; then
	. "$SSH_ENV" > /dev/null
    fi
    ps -ef | grep "$SSH_AGENT_PID" | grep ssh-agent > /dev/null
    if [ $? -eq 0 ]; then
        test_identities
    else
        start_agent
    fi
fi

#####################################################################
#####################################################################
#####################################################################

# show current git branch (as per http://railstips.org/blog/archives/2009/02/02/bedazzle-your-bash-prompt-with-git-info/)
function parse_git_branch {
  ref=$(git symbolic-ref HEAD 2> /dev/null) || return
  echo "("${ref#refs/heads/}")"
}

PS1="\[\e]0;\w\a\]\n\[\e[32m\]\u@\h \[\e[33m\]\w\[\e[0m\] \$(parse_git_branch)\n\$ "

#####################################################################
#####################################################################
#####################################################################

# make ls nicer

UNAME=`uname`

if [ "$UNAME" == "Darwin" ]; then
    export TERM=xterm-color
    alias ls='ls -G'
else
    alias ls='ls --color=auto'    
fi

alias l='ls -CF'
alias la='ls -A'
alias ll='ls -alF'

#####################################################################
#####################################################################
#####################################################################

# completion stuff
if [ -f /etc/bash_completion ] && ! shopt -oq posix; then
    . /etc/bash_completion
fi

#####################################################################
#####################################################################
#####################################################################

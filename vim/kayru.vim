" colour mode
set t_Co=256 

" enable syntax highlighting
syn on

" set reasonable fonts depending on OS
if has("mac")
	set gfn=Menlo:h11
elseif has("win32")
	set gfn=Consolas:h11
endif

" show line numbers
set number

" a tab is four spaces
set tabstop=4

" easy backspace
set backspace=2

" always set autoindenting on
set autoindent

" copy the previous indentation on autoindenting
set copyindent

" always show line numbers
set number

" number of spaces to use for autoindenting
set shiftwidth=4

" use multiple of shiftwidth when indenting with '<' and '>'
set shiftround

" set show matching parenthesis
set showmatch

" ignore case when searching
set ignorecase

" ignore case if search pattern is all lowercase, case-sensitive otherwise
set smartcase

" insert tabs on the start of a line according to shiftwidth, not tabstop
set smarttab

" highlight search terms
set hlsearch

" show search matches as you type
set incsearch

" remember more commands and search history
set history=1000

" use many muchos levels of undo
set undolevels=1000

" don't beep
" set visualbell  

" don't beep
set noerrorbells

" don't litter
set nobackup
set noswapfile

" nicer visible whitespace
set listchars=eol:$,tab:>-,trail:~,extends:>,precedes:<

" set nice colour scheme
color molokai

" easy mode
behave mswin



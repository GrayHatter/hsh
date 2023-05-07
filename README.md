# hsh
~~Don't use this, it's not ready!~~
You probably don't want to use this yet, while I have started to dog food this
as my shell... I'm crazy.

## Goals
 - Support *modern* pttys
 - Composable vs decomposable mode

## [De]composable mode
 A default, unconfigured install of hsh should enable all features and
 functionality. Running hsh non-interactive, or [other] should disable all
 helful, or context aware features unless explicitly enabled. 

## Install
install zig (you probably need zig master, or atleast > v0.10)<br>
clone [hsh]<br>
`zig build run`<br>

## TODO
 - [x] basic parsing
 - [x] exec
   - [ ] friendly exec
 - [ ] tab complete
   - [x] cwd
   - [ ] the rest
 - [x] history
   - [ ] advanced history
 - [ ] sane error handling
 - [ ] .hshrc support
 - [ ] complex parsing
 - [ ] context aware hints
 - [ ] built ins
   - [ ] alias
   - [ ] bg
   - [x] cd
   - [ ] colon
   - [ ] disown
   - [ ] dot
   - [ ] echo
   - [ ] eval
   - [ ] exec
   - [ ] export
   - [ ] fg
   - [ ] help
   - [ ] jobs
   - [ ] kill?
   - [ ] pwd
   - [ ] set
   - [ ] shift
   - [ ] source
   - [ ] unalias
   - [ ] unset
   - [ ] wait
   - [ ] which
   - [ ] the rest?
 - [ ] globs
 - [ ] script support?
 - [ ] env
 - [ ] real path support
 - [ ] debugging configuration


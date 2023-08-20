# hsh
~~Don't use this, it's not ready!~~
You probably don't want to use this yet, but it's my current default shell (what
could go wrong) so it might work for you if you're brave enough. I suspect you
need `zig version` `0.11.0` or better to compile.

Current technological breakthrough => "fire"

Hash is a slightly different take on your shell. It's closer to a user agent
than you standard POSIX shell. It's less of an instance, of a shell, and much
closer to a system shell. E.g. when you add an alias in one instance, it becomes
available on all instances as well. Changing a setting in one, updates it across
all[^ephem].

[^ephem]: There ~~is~~ will eventually be an ephemeral mode to allow any instance
    to have it's own settings without affecting your other shells on the system.

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
~~`zig build run`~~<br>
`zig build`<br>
`./zig-out/bin/hsh`

or `zig build -p /usr/` if you're brave enough to install into /usr/bin/hsh

## TODO
  - [x] basic parsing
  - [x] .hshrc support
  - [x] exec
    - [x] friendly exec
    - [x] && success
    - [x] || failures
    - [x] ; cmd
  - [ ] IoRedir
    - [x] | func
    - [x] > std clobber
    - [x] >> std append
    - [ ] 2> err clobber
    - [ ] 2>&1 err to out
    - [x] < in
    - [ ] << here-doc;
  - [ ] tab complete
    - [x] cwd
    - [x] path
    - [x] subdirs
    - [x] basic fuzzy search
    - [ ] narrow fuzzy search
    - [ ] ~, and glob
    - [ ] the rest?
  - [x] history
    - [ ] advanced history
  - [ ] sane error handling
  - [ ] complex parsing
  - [ ] context aware hints
  - [ ] built ins
    - [x] alias
    - [ ] bg
    - [x] cd
      - [ ] popd
    - [ ] colon
    - [ ] date
    - [x] die
    - [ ] disown
    - [ ] dot
    - [x] echo
    - [ ] eval
    - [ ] exec
    - [ ] exit
    - [ ] export
    - [ ] fg
    - [x] jobs
    - [ ] kill?
    - [ ] pipeline
    - [ ] pwd
    - [ ] read
    - [ ] set
    - [ ] shift
    - [ ] source
    - [ ] unalias
    - [ ] unset
    - [ ] wait
    - [ ] the rest?
  - [ ] HSH builtins
    - [ ] help
    - [ ] show
    - [ ] state
    - [ ] status
  - [x] globs
    - [x] simple globs
    - [ ] recursive globs
    - [ ] enumerated globs (name.{ext,exe,md,txt})
  - [ ] script support?
    - [ ] logic (if, else, elif, case)
    - [ ] loops (for, while)
  - [ ] env
  - [ ] real path support
  - [ ] debugging configuration

## notes
(`zig build run` does some magic that causes hsh to segv)

## Hash Manifesto
  * Subsume the Unix Philosophy
    * Don't do anything you can trust something else to do.
  * Remember you're a user agent! Make all decisions to protect their best
    interests. Aggressively protect and preserve data and actions.
  * Do not clobber backlog!
    * history is immutable, once data leaves the prompt, i.e. it has been pushed
      into the scroll back, the user owns it.

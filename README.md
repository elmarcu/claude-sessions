# claude-sessions

A single-file Bash script to browse your [Claude Code](https://claude.com/claude-code) sessions: filter them as you type, search inside their contents, then resume, clone or delete them.

It's one Bash file with no install step beyond `jq`.

```
#  MODIFIED     |   SIZE | MSGS | BRANCH             | ID       | TITLE                          | MATCH
1) Nov 16 16:43 |  8327K |   42 | feat/auth-refresh  | 3f2a9c1e | fix-token-refresh              | "text":"the refresh token is stored in redis with a TTL…
2) Nov 16 14:49 |  8805K |   17 | main               | 8b47d0e2 | api-cache-layer                | content":"add a redis cache in front of the users…

Type to filter · Tab title/content · Enter open first · Backspace edit · Ctrl-U/Esc clear · / commands
Filter [content]: redis
```

## Features

- **Filter as you type.** The list narrows on every keystroke, matching titles case-insensitively.
- **Search inside sessions.** Press <kbd>Tab</kbd> to switch to content search: it looks through everything in each session (your messages, Claude's replies, tool output) and shows the matched text in context, highlighted.
- **Resume, and come back.** <kbd>Enter</kbd> resumes the top session in its original working directory. When you exit Claude, you're back in the list.
- **Clone (fork) sessions.** Copies a session under a new ID, titled `<title>_forked`, so you can branch a conversation and keep the original.
- **Delete sessions,** including their subagent transcripts and tool results, after a confirmation.
- **Useful columns:** last modified, size, how many messages you typed, git branch, short ID and title (your `/rename` title, else Claude's generated title, else your first message).
- **Finds the right project on its own** (see below).

## Requirements

- Bash 3.2 or newer (the macOS default works)
- [`jq`](https://jqlang.org/)
- Optional: [`rg` (ripgrep)](https://github.com/BurntSushi/ripgrep) for much faster content search. Falls back to `grep`.
- `uuidgen`, or Linux's `/proc/sys/kernel/random/uuid`, for cloning

```sh
# macOS
brew install jq ripgrep
# Debian / Ubuntu
sudo apt install jq ripgrep
```

## Install

```sh
curl -fsSL -o ~/.local/bin/claude-sessions https://raw.githubusercontent.com/<you>/<repo>/main/claude-sessions.sh
chmod +x ~/.local/bin/claude-sessions
```

Or clone the repo and run `./claude-sessions.sh`.

### Alias

To launch it with a short command, add an alias to your shell config (`~/.zshrc` on macOS, `~/.bashrc` on most Linux systems):

```sh
# Installed with curl as above
alias cs='claude-sessions'

# Or pointing at a cloned repo
alias cs='bash ~/path/to/repo/claude-sessions.sh'

# Or always opening one project's sessions, wherever you are
alias cs-work='claude-sessions ~/.claude/projects/-Users-me-work-myproject'
```

Then reload your config (`source ~/.zshrc`, or open a new terminal) and run `cs`.

## Usage

```sh
claude-sessions               # sessions for the current folder's project
claude-sessions <folder>      # sessions in a specific ~/.claude/projects/<project> folder
```

Without an argument it looks, in order:

1. In the current folder, if it contains session files (`*.jsonl`).
2. In the Claude project for the current folder: `~/.claude/projects/<path with / and . replaced by ->`.
3. If neither has sessions, it lists every project under `~/.claude/projects` (most recent first) and asks you to pick one.

### Keys (list screen)

| Key | Action |
| --- | --- |
| any text | Filter the list |
| <kbd>Tab</kbd> | Switch between title and content search |
| <kbd>Enter</kbd> | Resume the first session in the list |
| <kbd>Backspace</kbd> | Delete the last character |
| <kbd>Ctrl</kbd>+<kbd>U</kbd> / <kbd>Esc</kbd> | Clear the filter |
| <kbd>/</kbd> | Open the command prompt |
| <kbd>Ctrl</kbd>+<kbd>C</kbd> | Quit |

### Commands (after <kbd>/</kbd>)

Commands use the numbers of the list you're looking at, so you can filter first and then act on the matches.

| Command | Action |
| --- | --- |
| `3` or `3f2a9c1e` | Resume session #3, or the session whose ID starts with `3f2a9c1e` |
| `c 3` · `c 1,4` · `c 2-5` | Clone one or more sessions |
| `d 3` · `d 1,4` · `d 2-5` | Delete one or more sessions (asks to confirm) |
| `q` | Quit |

## How it works

Claude Code stores each session as a JSON Lines file at `~/.claude/projects/<project>/<session-id>.jsonl`, with an optional `<session-id>/` folder for subagent transcripts and tool results. The script reads those files directly:

- **Listing** parses each file once with `jq` for its title, branch, folder and message count.
- **Content search** runs `rg` (or `grep`) for the first matching line in each file, then cuts a short extract around the match. Because the files are JSON, the query is escaped the same way (`\` → `\\`, `"` → `\"`) before searching.
- **Clone** copies the file under a new UUID, rewrites the session ID on every line, appends a `custom-title` record (Claude Code uses the last one), and copies the side folder.
- **Delete** removes the file and its side folder.

## Compatibility

- Tested on macOS (Bash 3.2, BSD tools) with Claude Code 2.1.311.
- On Linux, the macOS/GNU differences (`stat`, `date`, UUIDs, `Esc` timing) are handled by explicit branches, which were tested with GNU-style stand-ins but **not yet on a real Linux machine**. Reports and fixes are welcome.
- The session file format is internal to Claude Code and undocumented, so a future Claude Code release could change it. If titles or columns look wrong after an update, please open an issue with your Claude Code version.

## Known limitations

- On Bash 3.2 (macOS default), a bare <kbd>Esc</kbd> takes about a second to clear the filter, because Bash 3.2 can't wait for less than a whole second. <kbd>Ctrl</kbd>+<kbd>U</kbd> clears instantly. Bash 4+ has no delay.
- Content search matches within a single line of the session file, so a phrase that spans a line break inside a message won't match.
- Deleting is permanent. There's no undo or trash.
- The list shows only as many sessions as fit in the terminal. Numbers past the bottom still work in commands, but filtering is the easier way to reach them.

## License

MIT — free to use and extend.
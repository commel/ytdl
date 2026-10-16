# AGENTS.md

## Stack

- Single-file Tcl/Tk app: `ytdl.tcl`. No build step, no test framework, no package manager.
- Runtime: `wish` (Tk-enabled Tcl). Run with `wish ytdl.tcl` or `./ytdl.tcl`.
- No external Tcl packages — only stdlib + Tk (8.5+ for `ttk::*`).

## Specification

- Frontend accepts a URL and appends it to a queue.
- Queue is worked automatically, one item at a time (serial, not parallel).
- Each URL is passed to a configurable download command.

## Architecture

- All state lives in `::` namespace globals: `::queue` (list of dicts), `::download_cmd`, `::dest_dir`, `::active_pipe`, `::active_id`, `::W` (widget registry array).
- Persistence:
  - `ytdl.conf` (same dir as script) — settings (`cmd`, `destdir`), Tcl key-value list format.
  - `~/.ytdl_queue` (home dir) — queue state, one `id url status` entry per line.
  - Items in `downloading` state are reset to `pending` on load (crash recovery).
- Async subprocess via `open "|$cmd 2>@1" r` + `fileevent` readable handler; non-blocking pipe.
- Error detection: `close $pipe` returns non-empty string on non-zero exit.
- UI uses `grid` geometry manager throughout; dark theme is hard-coded in `build_ui`.
- `after 200 worker_kick` on startup resumes any pending items from prior session.
- `after 100 worker_kick` in `worker_finish` debounces start of next item.

## Key procs

| Proc | Role |
|---|---|
| `queue_add` | Append URL, save, refresh UI, kick worker |
| `worker_kick` | Find first `pending` item, start it (no-op if active) |
| `worker_start` | Launch subprocess, wire `fileevent` |
| `worker_read` | Stream output to UI text widget; call `worker_finish` on EOF |
| `build_ui` | Create all widgets; called once at startup |
| `config_load/save` | Read/write `ytdl.conf` |
| `queue_load/save` | Read/write `~/.ytdl_queue` |

## Conventions

- Add new settings to `ytdl.conf` as additional key-value pairs; load/save via `array set`/`array get`.
- Widget paths are registered in `::W(name)` — use this instead of hardcoded paths.
- Status values: `pending`, `downloading`, `done`, `error`.
- The listbox shows badges: `WAIT`, `DL..`, `DONE`, `ERR` with per-status colors.

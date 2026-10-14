# ytdl

A small Tcl/Tk desktop GUI frontend for [yt-dlp](https://github.com/yt-dlp/yt-dlp) with download queue functionality.

## What it does

Paste a URL into the input field and it gets added to a queue. The app works through the queue automatically, one item at a time, streaming the download output live to the UI. Queue state is persisted across sessions — if the app crashes or is closed mid-download, pending items resume on next start.

## Features

- URL queue with serial, automatic processing
- Live output streaming per queue item
- Configurable download command (default: `yt`, a `yt-dlp` shell alias)
- Configurable output directory
- Crash recovery: incomplete downloads are reset to pending on restart

## Requirements

- `wish` (Tcl/Tk 8.5+)
- `yt-dlp` or any compatible CLI tool that accepts `-P <dir> <url>`

## Usage

```bash
wish ytdl.tcl
# or, if the file is executable:
./ytdl.tcl
```

Settings (download command and output directory) can be changed directly in the UI and are saved to `ytdl.conf` in the same directory as the script.

## About

This app was vibecoded for learning purposes using [Claude](https://claude.ai) and [OpenCode](https://opencode.ai).

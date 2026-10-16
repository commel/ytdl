---
name: config-management
description: Use this when handling configuration values
---

# Config management

## When to use this skill
Use this when handling configuration values. Configurable values are:
- cmd, the command that is used to download youtube-videos. The cmd usually contains parameters and substitutable parameters like <url> and <target_dir>
- target_dir, the directory where the videos should be put to.

## How to read and write config values to the configuration file
Read these values at program start and put the values in local variables. After hitting "save" the variables defined here should be save to the configuration file.

# configuration file
The configuration file should be a simple ini files containing no section and a key=value store format. Read and write the configuration in that format.
At start of the software check for a configuration file `ytdl.conf` and if present, load the values from there. keep a variable per defined configuration value.
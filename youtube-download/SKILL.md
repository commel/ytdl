---
name: youtube-download
description: Download youtube videos through cli command
---

# Youtube Video Download

## When to use this skill
Use this skill when you get the command to download a youtube video by url.

## How to download a video
Download a video by using a cli command defined by the "cmd" parameter. The command should accept 2 substitutable parameters:
- <target_dir> 
- <url>
which both can be handled in the `configuration-management`-Skill. 

If nothing is defined use the default:

  yt-dlp_linux --cookies-from-browser vivaldi --js-runtime node -P <target_dir> <url>

the parameters "<target_dir>" and "<url>" will be replaced by the proper defined values in the variables.

---
name: versioning
description: Use this skill when versions or tags are used
---

# Versioning

## When to use this skill
The versioning scheme of this application follows SemVer: A.B.C. Where A is a stable major release and features usually breaking changes. B describes minor releases, which contain smaller features but no breaking changes. C is reserved for patches of bugfixes and security fixes only.

## Where is the version defined
In the main application `ytdl.tcl` there should a version constant be defined with a string containing the version.

Beside that there is a git tag defined which should match the version defined in the `ytdl.tcl`. The tag name follows the format `vA.B.C` (e.g. `v0.3.0`), i.e. the version string prefixed with a lowercase `v`. Tags without the prefix (e.g. `0.3`) are not valid.
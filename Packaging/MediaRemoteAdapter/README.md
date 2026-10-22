# mediaremote-adapter, vendored

Upstream: https://github.com/ungive/mediaremote-adapter at `0e82bf1`
(BSD 3-Clause, Jonas van den Berg and contributors — `LICENSE`).

Why: macOS 15.4+ answers MediaRemote's "Now Playing" only to Apple-identified
processes. `/usr/bin/perl` is one; the Perl script loads this framework into
it and streams what is playing as JSON. Wingcord reads that stream for its
Now Playing presence (docs/CLIPS-PRESENCE.md, D4; checked working on 27.2).

Copied verbatim: `bin/mediaremote-adapter.pl`, `include/`, `src/adapter`,
`src/private`, `src/utility` — minus `src/adapter/test.m` (the `test` command, which needs the test client). Not copied: the test client, CMake, scripts.
**One change, marked `// Wingcord:` in `src/adapter/stream.m`:** the stream
stops when its parent process exits, so a Wingcord that crashed or was killed
leaves no `perl` behind (seen in testing, 2026-10-20: three orphans from three
demo launches).

Built by `scripts/build-mediaremote-adapter.sh` (plain clang, the upstream
CMake flags) into `build/MediaRemoteAdapter.framework`; the app scripts place
it in `Contents/Frameworks` and the Perl script in `Contents/Resources`.

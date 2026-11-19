# Experimental native CSS 1.0.380 shutdown probe

Build-only repository. Contains no game server, player data, credentials, private crash
dumps or MANIAC source. This is not an official CounterStrikeSharp release.

The workflow runs only after a manual `workflow_dispatch`. It does not run on push or
pull requests, create releases, publish packages, or install anything on a server.
Use a standard GitHub-hosted `windows-2022` runner. Public repository compute is free
under GitHub's standard runner policy; artifact storage has a separate quota.
Review account storage/usage before dispatch; a successful build is not guaranteed.

Pinned source: roflmuffin/CounterStrikeSharp commit
`2273dd1631a5719f2cacc6e9abbf67ac0bc30bc0` (v1.0.380). Recursive submodule
commits, diagnostic patch, patched source hashes and CMake archive are locked.
VS 2022 v143 and SDK 10.0.26100.0 are required on the runner, not on the operator's PC.
MSVC minor version and hosted image are recorded, not fully immutable. This recipe
is source-reproducible; it does not promise bit-identical DLLs across runner updates.

Only the native Windows x64 Release target is built. Managed API, .NET runtime,
Metamod and game resources are not replaced. The output includes the native DLL,
matching linker PDB, PE metadata, SHA-256, tool/build provenance and corresponding
upstream/dependency source archives plus patch/licenses. Artifact lifetime: one day.
Uncompressed artifact budget: 400 MiB; no cache or release upload.

Download only from the approved repository/commit and reviewed Actions run.
Verify GitHub's artifact digest and all internal SHA-256 values locally. A checksum
alone is not proof of origin. Check build-info source/patch/harness/run identity,
then re-run `python ci/verify_pe.py <candidate.dll> --lock locks/build.json`.
Require native AMD64, exports CreateInterface and InvokeNative and exactly the
reviewed import DLLs. New dependencies cause a hard failure, not automatic approval.

The diagnostic patch unregisters and invalidates two static command references early
in ConCommandManager::OnShutdown. The `ShutdownProbe:` log markers must show entry
and valid_after=0 for registered commands. Absence of a marker or a crash is a failed
diagnostic result, not a clean STOP. Only a separately approved real CS2 test can
verify engine compatibility and shutdown order.

License: upstream GPLv3 with its stated exception. See included upstream license.
Changes in this repository to upstream code remain under the upstream terms;
build/check scripts may be used under GPLv3. No ownership of upstream code is claimed.

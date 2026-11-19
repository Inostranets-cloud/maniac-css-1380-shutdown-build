param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Output)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Only a standard GitHub-hosted Windows runner is approved by this build recipe'
}
$harness = Split-Path $PSScriptRoot -Parent
$harnessCommit = & git -C $harness rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $harnessCommit -ne $env:GITHUB_SHA) { throw 'Harness commit differs from the dispatched workflow' }
$harnessDirty = & git -C $harness status --porcelain --untracked-files=all
if ($LASTEXITCODE -ne 0 -or $harnessDirty) { throw 'Harness checkout is not clean' }
$sourcePath = (Resolve-Path -LiteralPath $Source).Path
$outputPath = [IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $outputPath) { throw 'Output must be a new directory' }
$lock = Get-Content -Raw -LiteralPath "$harness/locks/build.json" | ConvertFrom-Json
$submodules = Get-Content -Raw -LiteralPath "$harness/locks/submodules.json" | ConvertFrom-Json
function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed with $LASTEXITCODE" }
}
function Get-Git([string[]]$Arguments) {
    $result = & git -C $sourcePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Git verification failed' }
    return $result
}
if ((Get-Git @('rev-parse','HEAD')) -ne $lock.source_commit) { throw 'Source commit mismatch' }
if (Get-Git @('status','--porcelain','--untracked-files=all')) { throw 'Source checkout is not clean' }
$actualModules = @{}
foreach ($line in (Get-Git @('submodule','status','--recursive'))) {
    if ($line -notmatch '^ ([0-9a-f]{40}) ([^ ]+)(?: .*)?$') { throw "Invalid submodule state: $line" }
    $actualModules[$Matches[2]] = $Matches[1]
}
if ($actualModules.Count -ne @($submodules.PSObject.Properties).Count) { throw 'Submodule count mismatch' }
foreach ($item in $submodules.PSObject.Properties) {
    if ($actualModules[$item.Name] -ne $item.Value) { throw "Submodule mismatch: $($item.Name)" }
    $dirty = & git -C "$sourcePath/$($item.Name)" status --porcelain --untracked-files=all
    if ($LASTEXITCODE -ne 0 -or $dirty) { throw "Dirty submodule: $($item.Name)" }
}
$patch = "$harness/patches/shutdown-diagnostic.patch"
if ((Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant() -ne $lock.patch_sha256) {
    throw 'Patch digest mismatch'
}
Invoke-Checked git @('-C',$sourcePath,'apply','--check',$patch)
Invoke-Checked git @('-C',$sourcePath,'apply',$patch)
$changed = @(Get-Git @('diff','--name-only'))
if (@(Compare-Object @($lock.source_after.PSObject.Properties.Name) $changed).Count) {
    throw 'Patch changed unexpected source files'
}
foreach ($item in $lock.source_after.PSObject.Properties) {
    $sourceFile = "$sourcePath/$($item.Name)"
    $normalized = [IO.File]::ReadAllText($sourceFile).Replace("`r`n","`n")
    [IO.File]::WriteAllText($sourceFile,$normalized,[Text.UTF8Encoding]::new($false))
    if ((Get-FileHash "$sourcePath/$($item.Name)" -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.Value) {
        throw "Patched source digest mismatch: $($item.Name)"
    }
}
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs = & $vswhere -latest -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vs) { throw 'Visual Studio 2022 C++ toolchain missing on runner' }
$devcmd = Join-Path $vs 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path -LiteralPath $devcmd -PathType Leaf)) { throw 'VsDevCmd.bat missing from the selected Visual Studio installation' }
# Pass cmd.exe its raw command line. Keep the path in the child environment so
# PowerShell does not serialize the nested quotes as native arguments.
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = "$env:SystemRoot\System32\cmd.exe"
$startInfo.Arguments = '/d /s /v:off /u /c ""%CSS_BUILD_VSDEVCMD%" -arch=x64 -host_arch=x64 >nul && set"'
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.StandardOutputEncoding = [Text.Encoding]::Unicode
$startInfo.EnvironmentVariables['CSS_BUILD_VSDEVCMD'] = $devcmd
$process = [Diagnostics.Process]::Start($startInfo)
try {
    $environment = $process.StandardOutput.ReadToEnd() -split '\r?\n'
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Cannot initialize x64 compiler environment (cmd.exe exit $($process.ExitCode))" }
} finally {
    $process.Dispose()
}
foreach ($line in $environment) {
    if ($line -match '^([^=]+)=(.*)$' -and $Matches[1] -ne 'CSS_BUILD_VSDEVCMD') {
        [Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process')
    }
}
$sdk = Join-Path ${env:ProgramFiles(x86)} "Windows Kits/10/Include/$($lock.windows_sdk)/um/Windows.h"
if (-not (Test-Path -LiteralPath $sdk)) { throw 'Pinned Windows SDK missing; do not install another automatically' }
$tools = Join-Path $env:RUNNER_TEMP 'css-pinned-cmake'
if (Test-Path -LiteralPath $tools) { throw 'Tool extraction directory already exists' }
New-Item -ItemType Directory -Path $tools | Out-Null
$zip = Join-Path $tools 'cmake.zip'
Invoke-WebRequest -Uri $lock.cmake_url -OutFile $zip
if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $lock.cmake_sha256) { throw 'CMake archive hash mismatch' }
Expand-Archive -LiteralPath $zip -DestinationPath $tools
$cmake = Join-Path $tools 'cmake-3.31.12-windows-x86_64/bin/cmake.exe'
$build = Join-Path $env:RUNNER_TEMP 'css-native-build'
if (Test-Path -LiteralPath $build) { throw 'Build directory already exists' }
$env:SEMVER = '1.0.380'
$env:GITHUB_SHA_SHORT = '2273dd1'
Invoke-Checked $cmake @('-S',$sourcePath,'-B',$build,'-G','Visual Studio 17 2022','-A','x64','-T','v143',
    "-DCMAKE_SYSTEM_VERSION=$($lock.windows_sdk)",'-DCMAKE_BUILD_TYPE=Release',
    '-DCMAKE_SHARED_LINKER_FLAGS_RELEASE=/DEBUG:FULL /OPT:REF /OPT:ICF /Brepro')
Invoke-Checked $cmake @('--build',$build,'--config','Release','--target','counterstrikesharp','--','/m:2')
$dll = @(Get-ChildItem -LiteralPath "$build/Release" -Filter counterstrikesharp.dll -File)
$pdb = @(Get-ChildItem -LiteralPath "$build/Release" -Filter counterstrikesharp.pdb -File)
if ($dll.Count -ne 1 -or $pdb.Count -ne 1) { throw 'Expected exactly one native DLL and linker PDB' }
New-Item -ItemType Directory -Path $outputPath | Out-Null
Copy-Item -LiteralPath $dll[0].FullName -Destination "$outputPath/counterstrikesharp.dll"
Copy-Item -LiteralPath $pdb[0].FullName -Destination "$outputPath/counterstrikesharp.pdb"
Invoke-Checked python @("$harness/ci/verify_pe.py","$outputPath/counterstrikesharp.dll",'--lock',"$harness/locks/build.json",'--require-probe','--output',"$outputPath/pe.json")
$candidate = Get-Content -Raw -LiteralPath "$outputPath/pe.json" | ConvertFrom-Json
if ($candidate.sha256 -eq $lock.official_native_sha256) { throw 'Candidate unexpectedly identical to unpatched official DLL' }
New-Item -ItemType Directory -Path "$outputPath/corresponding-source" | Out-Null
Invoke-Checked git @('-C',$sourcePath,'archive','--format=tar',"--output=$outputPath/corresponding-source/upstream.tar",$lock.source_commit)
# The archive excludes gitlinks; ship exact recursive dependency sources as well.
foreach ($item in $submodules.PSObject.Properties) {
    $archiveName = $item.Name.Replace('/','__') + '.tar'
    Invoke-Checked git @('-C',"$sourcePath/$($item.Name)",'archive','--format=tar',"--output=$outputPath/corresponding-source/$archiveName",$item.Value)
}
Copy-Item -LiteralPath $patch -Destination "$outputPath/shutdown-diagnostic.patch"
Copy-Item -LiteralPath "$harness/locks/build.json","$harness/locks/submodules.json" -Destination "$outputPath/"
Copy-Item -LiteralPath "$sourcePath/LICENSE","$sourcePath/LICENSE.GPL3","$sourcePath/LICENSE.MIT" -Destination "$outputPath/"
Copy-Item -LiteralPath "$build/CMakeCache.txt" -Destination "$outputPath/CMakeCache.txt"
$cl = (& cmd.exe /d /c 'cl.exe /Bv 2>&1' | Out-String)
$cmakeVersion = (& $cmake --version | Out-String)
$info = [ordered]@{
    experimental = $true; upstream = 'roflmuffin/CounterStrikeSharp'; source_commit = $lock.source_commit
    patch_sha256 = $lock.patch_sha256; candidate_sha256 = $candidate.sha256
    harness_repository = $env:GITHUB_REPOSITORY; harness_commit = $env:GITHUB_SHA
    run_id = $env:GITHUB_RUN_ID; run_attempt = $env:GITHUB_RUN_ATTEMPT
    run_url = "https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    runner_image = $env:ImageOS; runner_image_version = $env:ImageVersion
    visual_studio = $vs; compiler = $cl; compiler_version = $env:VCToolsVersion
    cmake = $cmakeVersion; sdk = $lock.windows_sdk; python = (& python --version | Out-String).Trim()
    semver = $env:SEMVER; architecture = 'AMD64'; configuration = 'Release'; crt = 'static /MT'
    runtime_verified = $false; clean_stop_verified = $false
}
$info | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$outputPath/build-info.json" -Encoding utf8NoBOM
@"
Experimental native-only build. Not an official CSS release and not runtime verified.
Reconstruct corresponding source: extract upstream.tar into a new directory, extract each
dependency archive into the matching libraries path (see submodules.json), apply the patch.
Build with the public harness commit recorded in build-info.json; preserve licenses.
No managed API or runtime DLL is replaced by this artifact. No CS2 resources included.
"@ | Set-Content -LiteralPath "$outputPath/SOURCE-README.txt" -Encoding utf8NoBOM
$files = @(Get-ChildItem -LiteralPath $outputPath -Recurse -File)
if (($files | Measure-Object Length -Sum).Sum -gt 400MB) { throw 'Artifact exceeds the reviewed 400 MiB storage budget' }
$sums = foreach ($file in ($files | Sort-Object FullName)) {
    $relative = [IO.Path]::GetRelativePath($outputPath,$file.FullName).Replace('\','/')
    "$((Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $relative"
}
$sums | Set-Content -LiteralPath "$outputPath/SHA256SUMS.txt" -Encoding utf8NoBOM
Write-Output "Candidate SHA-256: $($candidate.sha256). NOT installed; live STOP is unverified."

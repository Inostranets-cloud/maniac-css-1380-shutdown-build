"""Read-only acceptance checks. Does not extract ZIP, install DLLs or launch CS2."""
import argparse
import hashlib
import json
import re
from pathlib import Path, PurePosixPath
from verify_pe import inspect, validate


def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def safe_file(root, relative):
    part = PurePosixPath(relative)
    if part.is_absolute() or '..' in part.parts or '\\' in relative or ':' in relative:
        raise ValueError('Unsafe manifest path')
    file = root.joinpath(*part.parts)
    if not file.is_file(): raise ValueError('Missing artifact file: '+relative)
    for item in (file, *file.parents):
        if item == root.parent: break
        if item.is_symlink() or getattr(item.stat(), 'st_file_attributes', 0) & 0x400:
            raise ValueError('Reparse point in artifact')
    return file


def verify(bundle, lock_dir, harness_commit, run_id):
    root = Path(bundle).absolute()
    if not re.fullmatch('[0-9a-f]{40}', harness_commit) or not run_id.isdigit():
        raise ValueError('Use the independently approved full harness commit and Actions run ID')
    lock = json.loads((lock_dir/'build.json').read_text(encoding='utf-8-sig'))
    for name in ('build.json','submodules.json'):
        if json.loads(safe_file(root,name).read_text(encoding='utf-8-sig')) != json.loads((lock_dir/name).read_text(encoding='utf-8-sig')):
            raise ValueError('Artifact locks differ from reviewed local locks')
    listed = set()
    for line in safe_file(root,'SHA256SUMS.txt').read_text(encoding='utf-8-sig').splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  (.+)', line)
        if not match: raise ValueError('Invalid checksum record')
        expected, relative = match.groups()
        if relative in listed or relative == 'SHA256SUMS.txt': raise ValueError('Duplicate/self-referential manifest entry')
        listed.add(relative)
        if digest(safe_file(root, relative)) != expected: raise ValueError('Checksum mismatch: '+relative)
    actual = {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()}
    if actual != listed | {'SHA256SUMS.txt'}: raise ValueError('Unlisted/missing artifact files')
    required = {'counterstrikesharp.dll','counterstrikesharp.pdb','pe.json','build-info.json',
                'build.json','submodules.json','shutdown-diagnostic.patch','LICENSE',
                'LICENSE.GPL3','LICENSE.MIT','SOURCE-README.txt','CMakeCache.txt',
                'corresponding-source/upstream.tar'}
    modules = json.loads((lock_dir/'submodules.json').read_text())
    required.update('corresponding-source/'+p.replace('/','__')+'.tar' for p in modules)
    if listed != required: raise ValueError('Artifact allowlist mismatch')
    info = json.loads(safe_file(root,'build-info.json').read_text(encoding='utf-8-sig'))
    expected = {'experimental': True, 'source_commit': lock['source_commit'],
                'patch_sha256': lock['patch_sha256'], 'harness_commit': harness_commit,
                'run_id': run_id, 'semver': '1.0.380', 'architecture': 'AMD64',
                'runtime_verified': False, 'clean_stop_verified': False}
    for key, value in expected.items():
        if info.get(key) != value: raise ValueError('Provenance mismatch: '+key)
    if digest(safe_file(root,'shutdown-diagnostic.patch')) != lock['patch_sha256']:
        raise ValueError('Diagnostic patch mismatch')
    pe = inspect(safe_file(root,'counterstrikesharp.dll'))
    validate(pe, lock, require_probe=True)
    if pe['sha256'] == lock['official_native_sha256'] or info.get('candidate_sha256') != pe['sha256']:
        raise ValueError('Candidate is unpatched or provenance SHA differs')
    if pe != json.loads(safe_file(root,'pe.json').read_text(encoding='utf-8-sig')):
        raise ValueError('PE metadata mismatch')
    if not safe_file(root,'counterstrikesharp.pdb').read_bytes().startswith(b'Microsoft C/C++ MSF 7.00'):
        raise ValueError('Expected native MSF PDB')
    return {'status':'OFFLINE CANDIDATE VERIFIED', 'sha256':pe['sha256'],
            'installed':False, 'runtime_verified':False, 'clean_stop_verified':False}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bundle',type=Path,required=True)
    p.add_argument('--lock-dir',type=Path,required=True)
    p.add_argument('--harness-commit',required=True)
    p.add_argument('--run-id',required=True)
    p.add_argument('--artifact-zip',type=Path,required=True)
    p.add_argument('--artifact-sha256',required=True,help='Approved digest from the reviewed GitHub Actions run')
    a = p.parse_args()
    if not re.fullmatch('[0-9a-fA-F]{64}',a.artifact_sha256) or digest(a.artifact_zip) != a.artifact_sha256.lower():
        raise ValueError('GitHub artifact ZIP digest mismatch')
    print(json.dumps(verify(a.bundle,a.lock_dir,a.harness_commit,a.run_id),indent=2))


if __name__ == '__main__': main()

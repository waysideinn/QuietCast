#!/usr/bin/env python3
"""Scan a publish tree without printing secret values. Exit nonzero on findings."""
import argparse
import pathlib
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('root', nargs='?', default='.')
args = parser.parse_args()
root = pathlib.Path(args.root).resolve()
skip = {'.git', '.build', 'build', 'DerivedData', 'Share', '__pycache__', '.swiftpm'}
private_dirs = {'.aws', '.codex', '.agents', 'xcuserdata', 'device-backups', 'private'}
patterns = {
    'GitHub credential': r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})',
    'AWS access key': r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b',
    'private key': r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'home path': r'/' + r'Users/[^/\s\x60\"\x27]+/',
    'private IPv4': r'\b(?:192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3})\b',
    'personal Xcode team': r'DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}\b',
    'assigned credential': r'(?i)(?:api_key|apiKey|access_token|client_secret|secret_key)\s*[=:]\s*[\x22\x27][A-Za-z0-9_+/=-]{24,}',
}
findings = []
count = 0
for path in sorted(root.rglob('*')):
    rel = path.relative_to(root)
    if set(rel.parts) & skip or not path.is_file():
        continue
    if path.is_symlink():
        findings.append((str(rel), 'symlink requires review'))
        continue
    if set(rel.parts) & private_dirs or path.suffix.lower() in {'.ipa', '.p12', '.pfx', '.pem', '.key', '.mobileprovision', '.provisionprofile', '.cer'} or path.name == '.env' or (path.name.startswith('.env.') and path.name != '.env.example'):
        findings.append((str(rel), 'private file type'))
        continue
    try:
        data = path.read_text()
    except (UnicodeError, OSError):
        continue
    count += 1
    for label, pattern in patterns.items():
        if re.search(pattern, data):
            findings.append((str(rel), label))
# Commit history can disclose identities even when file contents are clean.
if (root / '.git').exists():
    result = subprocess.run(['git', '-C', str(root), 'log', '--all', '--format=%an <%ae> | %cn <%ce>'], capture_output=True, text=True)
    if result.returncode == 0:
        for identity in set(result.stdout.splitlines()):
            if identity and identity != 'QuietCast Contributors <quietcast@example.invalid> | QuietCast Contributors <quietcast@example.invalid>':
                findings.append(('.git history', 'non-project author identity; review locally'))
                break
for name, reason in findings:
    print(f'REVIEW: {name}: {reason}')
print(f'Scanned {count} text files; {len(findings)} finding(s). Values are never printed.')
raise SystemExit(1 if findings else 0)

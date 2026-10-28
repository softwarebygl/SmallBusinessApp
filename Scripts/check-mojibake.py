#!/usr/bin/env python3
"""Block commits containing double-encoded UTF-8 (mojibake).

A run of 2+ chars in U+0080-U+00FF that round-trips latin-1 -> UTF-8 is
almost certainly UTF-8 text that was re-read as Latin-1 ("Select…" ->
"Selectâ¦"). Legit accented chars (Portuguese "câmera", lone · or ×) fail
the round-trip and pass the check.

Usage:
  check-mojibake.py --staged        # scan staged blobs (pre-commit hook)
  check-mojibake.py FILE [FILE...]  # scan working-tree files
"""
import re
import subprocess
import sys

TEXT_EXTS = {'.swift', '.md', '.ts', '.tsx', '.js', '.jsx', '.html', '.css',
             '.json', '.py', '.sh', '.yml', '.yaml', '.txt', '.xml', '.plist',
             '.strings', '.xcstrings', '.entitlements', '.xcconfig', '.toml',
             '.svg', '.mjs', '.cjs', '.pbxproj'}

RUN = re.compile('[' + chr(0x80) + '-' + chr(0xFF) + ']{2,}')


def is_mojibake(run: str) -> bool:
    try:
        run.encode('latin-1').decode('utf-8')
        return True
    except (UnicodeEncodeError, UnicodeDecodeError):
        return False


def scan(name: str, text: str) -> list[str]:
    problems = []
    for lineno, line in enumerate(text.splitlines(), 1):
        for m in RUN.finditer(line):
            if is_mojibake(m.group()):
                problems.append(f'{name}:{lineno}: {line.strip()[:120]}')
                break
    return problems


def main() -> int:
    problems = []
    if sys.argv[1:] == ['--staged']:
        out = subprocess.run(
            ['git', 'diff', '--cached', '--name-only', '--diff-filter=ACM'],
            capture_output=True, text=True, check=True).stdout
        for path in out.splitlines():
            if not any(path.lower().endswith(e) for e in TEXT_EXTS):
                continue
            blob = subprocess.run(['git', 'show', ':' + path],
                                  capture_output=True, check=True).stdout
            try:
                problems += scan(path, blob.decode('utf-8'))
            except UnicodeDecodeError:
                problems.append(f'{path}: not valid UTF-8')
    else:
        for path in sys.argv[1:]:
            try:
                problems += scan(path, open(path, encoding='utf-8').read())
            except UnicodeDecodeError:
                problems.append(f'{path}: not valid UTF-8')

    if problems:
        print('COMMIT BLOCKED — double-encoded text (mojibake) detected:')
        print('\n'.join(problems))
        print('\nFix the encoding (reverse latin-1->utf-8 on the corrupted '
              'runs only), restage, and retry.')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Run A's same CLI tests in a temporary checkout view; no App/Source edits."""
import shutil
import subprocess
import tempfile
from pathlib import Path
from collect import ROOT,write

def main():
    log=ROOT/'reports/fiction_research/release/core-cli-tests.log'
    with tempfile.TemporaryDirectory(prefix='quietcast-b-core-tests-') as folder:
        work=Path(folder)
        for name in ('Sources','Tests','Package.swift'):
            (work/name).symlink_to(ROOT/name,target_is_directory=(ROOT/name).is_dir())
        (work/'Scripts').mkdir()
        for name in ('test-cli.sh','generate_cli_runner.py','core-object-list.py'):
            shutil.copy2(ROOT/'Scripts'/name,work/'Scripts'/name)
        with log.open('w') as output:
            result=subprocess.run(['sh',str(work/'Scripts/test-cli.sh')],cwd=work,stdout=output,stderr=subprocess.STDOUT)
    text=log.read_text()
    import re
    found=re.findall(r'(\d+) tests, (\d+) assertions, (\d+) failures',text)
    write(ROOT/'reports/fiction_research/release/core-cli-tests.json',dict(command='A Scripts/test-cli.sh, temporary source/test symlink view',exitCode=result.returncode,tests=int(found[-1][0]) if found else None,assertions=int(found[-1][1]) if found else None,failures=int(found[-1][2]) if found else None,log=str(log.relative_to(ROOT)),notes='CLI assertion adapter runs the same test functions; not XCTest or iOS device validation.'))
    print(text[-2200:])
    if result.returncode:raise SystemExit(result.returncode)

if __name__=='__main__':main()

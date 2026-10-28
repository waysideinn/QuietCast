from pathlib import Path
import re
calls=[]
for p in sorted(Path('Tests/PodcastCoreTests').glob('*Tests.swift')):
    text=p.read_text(); cls=re.search(r'final class (\w+Tests): XCTestCase',text)[1]
    for name,attrs in re.findall(r'func (test\w+)\(\)([^\{]*)\{',text):
        invocation=('try ' if 'throws' in attrs else '')+('await ' if 'async' in attrs else '')+f'test.{name}()'
        execution = f'do {{ {invocation} }} catch {{ XCTFail("Uncaught: \\(error)") }}' if 'throws' in attrs else invocation
        calls.append(f'''        do {{
            let test = {cls}(); let before = CLITestState.failures.count
            {execution}
            test.finish(); count += 1
            print("\\(CLITestState.failures.count == before ? "PASS" : "FAIL") {cls}.{name}")
        }}''')
Path('.build/CLIRunner.swift').write_text('''import Foundation
@main struct CoreTests {
    static func main() async {
        var count = 0
'''+ '\n'.join(calls)+'''
        print("\\(count) tests, \\(CLITestState.assertions) assertions, \\(CLITestState.failures.count) failures")
        if !CLITestState.failures.isEmpty { exit(1) }
    }
}
''')

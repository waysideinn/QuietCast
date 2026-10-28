from pathlib import Path
import json, sys
bin_dir = Path(sys.argv[1])
paths = [bin_dir/f'{module}.build'/f'{source.name}.o'
         for module in ('PodcastModels', 'ContentFiltering', 'PodcastCore')
         for source in sorted((Path('Sources')/module).glob('*.swift'))]
assert all(path.exists() for path in paths)
Path('.build/core-objects.txt').write_text('\n'.join(json.dumps(str(path), ensure_ascii=False) for path in paths)+'\n')

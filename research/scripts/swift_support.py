"""Build A's existing modules only in temporary storage; never modify the package."""
import hashlib
import subprocess
import tempfile
from pathlib import Path
from collect import ROOT

def compile_probe(folder):
    folder=Path(folder)
    cache=Path(tempfile.gettempdir())/'quietcast-fiction-swift-module-cache'
    common=['swiftc','-module-cache-path',str(cache)]
    model_files=sorted((ROOT/'Sources/PodcastModels').glob('*.swift'))
    filter_files=sorted((ROOT/'Sources/ContentFiltering').glob('*.swift'))
    probe=ROOT/'research/scripts/SwiftProbe.swift'
    sources=model_files+filter_files+[probe]
    if not model_files or not filter_files:raise RuntimeError('Expected A modular source files unavailable; do not modify A to accommodate probe')
    hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    commands=[common+['-emit-module','-emit-library','-module-name','PodcastModels','-emit-module-path',str(folder/'PodcastModels.swiftmodule'),'-o',str(folder/'libPodcastModels.dylib')]+list(map(str,model_files)),common+['-emit-module','-emit-library','-module-name','ContentFiltering','-I',str(folder),'-L',str(folder),'-lPodcastModels','-emit-module-path',str(folder/'ContentFiltering.swiftmodule'),'-o',str(folder/'libContentFiltering.dylib')]+list(map(str,filter_files)),common+['-parse-as-library','-I',str(folder),'-L',str(folder),'-lPodcastModels','-lContentFiltering','-Xlinker','-rpath','-Xlinker',str(folder),'-o',str(folder/'probe'),str(probe)]]
    for cmd in commands:
        result=subprocess.run(cmd,text=True,capture_output=True)
        if result.returncode:raise RuntimeError(result.stderr)
    after={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    if hashes!=after:raise RuntimeError('A sources changed during compilation; retry after source stabilizes')
    return folder/'probe',hashes

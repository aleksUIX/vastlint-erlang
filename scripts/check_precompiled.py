#!/usr/bin/env python3
"""Install a real release-format NIF through RustlerPrecompiled over local HTTP."""
import functools
import hashlib
import http.server
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading

root = Path(__file__).resolve().parent.parent
provenance = json.loads((root / "engine-release.json").read_text())
version = provenance["release_tag"][1:]
reported_version = provenance["nif_crate_version"]
targets = {
    ("Darwin", "arm64"): "aarch64-apple-darwin",
    ("Darwin", "x86_64"): "x86_64-apple-darwin",
    ("Linux", "x86_64"): "x86_64-unknown-linux-gnu",
    ("Linux", "aarch64"): "aarch64-unknown-linux-gnu",
}
target = targets[(platform.system(), platform.machine())]
library = root / "priv/native/vastlint_nif.so"

with tempfile.TemporaryDirectory(prefix="vastlint-precompiled-") as temporary:
    temporary = Path(temporary)
    archives = temporary / "archives"
    name = subprocess.check_output(
        ["bash", str(root / "scripts/package-nif.sh"), str(library), version, target, str(archives)],
        text=True,
    ).strip()
    digest = hashlib.sha256((archives / name).read_bytes()).hexdigest()
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(archives))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        project = temporary / "consumer"
        project.mkdir()
        shutil.copytree(root / "lib", project / "lib")
        shutil.copytree(root / "src", project / "src")
        for filename in ["mix.exs", "mix.lock"]:
            shutil.copy2(root / filename, project / filename)
        (project / "deps").symlink_to(root / "deps", target_is_directory=True)
        loader = project / "lib/vastlint_nif.ex"
        text = loader.read_text().replace(
            '"https://github.com/aleksUIX/vastlint-erlang/releases/download/v#{@version}"',
            f'"http://127.0.0.1:{server.server_port}/"',
        )
        loader.write_text(text)
        (project / "checksum-vastlint_nif.exs").write_text(
            f'%{{"{name}" => "sha256:{digest}"}}\n'
        )
        shutil.copy2(root / "test/fixtures/valid_inline_40.xml", project / "valid.xml")
        environment = dict(os.environ, MIX_ENV="prod", VASTLINT_BUILD="false")
        environment["RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH"] = str(temporary / "cache")
        for variable in ["MIX_BUILD_PATH", "MIX_DEPS_PATH", "RUSTLER_PRECOMPILED_FORCE_BUILD_ALL"]:
            environment.pop(variable, None)
        subprocess.run(["mix", "deps.compile"], cwd=project, env=environment, check=True)
        expression = (
            f'if Vastlint.version() != "{reported_version}", do: raise("wrong NIF crate version"); '
            '{:ok, result} = Vastlint.validate(File.read!("valid.xml")); '
            'if not result.valid, do: raise("valid fixture rejected")'
        )
        subprocess.run(["mix", "run", "-e", expression], cwd=project, env=environment, check=True)
        print(f"Precompiled NIF {version}: downloaded, checksum verified, loaded and validated.")
    finally:
        server.shutdown()
        server.server_close()

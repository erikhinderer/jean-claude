"""Fetch an unofficial WASI build of CPython (github.com/brettcannon/cpython-wasi-build),
lay it out as /opt/python-wasi/{python.wasm,lib/pythonX.Y}, and smoke-test it under
Wasmtime. On any failure, write UNAVAILABLE instead of failing the image build."""
import glob, json, os, re, shutil, subprocess, sys, tempfile, urllib.request, zipfile

want, dest = sys.argv[1], sys.argv[2]
os.makedirs(dest, exist_ok=True)

def fail(msg):
    open(os.path.join(dest, "UNAVAILABLE"), "w").write(
        f"WASI CPython is unavailable in this image: {msg}\nUse --backend container for Python projects.\n")
    print("python-wasi:", msg); sys.exit(0)

try:
    api = "https://api.github.com/repos/brettcannon/cpython-wasi-build/releases?per_page=50"
    releases = json.load(urllib.request.urlopen(api, timeout=60))
    pat = re.compile(r"^python-" + re.escape(want) + r"\.\d+.*\.zip$")
    asset = next((a for r in releases if not r.get("prerelease") and r["tag_name"].startswith("v" + want + ".")
                  for a in r["assets"] if pat.match(a["name"]) and "build" not in a["name"].lower()), None)
    if not asset:
        fail(f"no release asset for Python {want}")
    tmp = tempfile.mkdtemp()
    zpath = os.path.join(tmp, asset["name"])
    urllib.request.urlretrieve(asset["browser_download_url"], zpath)
    zipfile.ZipFile(zpath).extractall(tmp)
    wasm = next(iter(glob.glob(os.path.join(tmp, "**", "python*.wasm"), recursive=True)), None)
    stdlib = next(iter(glob.glob(os.path.join(tmp, "**", "lib", "python" + want), recursive=True)), None)
    if not wasm or not stdlib:
        fail(f"unexpected archive layout in {asset['name']}")
    shutil.copy(wasm, os.path.join(dest, "python.wasm"))
    shutil.copytree(stdlib, os.path.join(dest, "lib", "python" + want), dirs_exist_ok=True)
    open(os.path.join(dest, "VERSION"), "w").write(want)
    out = subprocess.run(["wasmtime", "run", "--dir", dest + "::/py", "--env", "PYTHONHOME=/py",
                          os.path.join(dest, "python.wasm"), "-c", "import sys; print(sys.version)"],
                         capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        fail("smoke test failed: " + (out.stderr or out.stdout)[-500:])
    print("python-wasi ready:", out.stdout.strip(), "from", asset["name"])
    shutil.rmtree(tmp, ignore_errors=True)
except SystemExit:
    raise
except Exception as e:  # network, API, zip errors
    fail(f"{type(e).__name__}: {e}")

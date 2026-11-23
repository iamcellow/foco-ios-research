"""Fetch exactly the Base model tested for this local research project."""
from pathlib import Path
import hashlib
import os
import shutil
import tempfile
from urllib.request import urlopen

ROOT=Path(__file__).resolve().parents[1]/"Foco"/"DepthBase.mlpackage"
REV="4e607a682f993bbf95035054fc78ba9ffc81faf2"
FILES={
    "Manifest.json":"f7a13538bebe8b592ae19fbf6c3aac303c8bfba44384109c00f69275be34be39",
    "Data/com.apple.CoreML/model.mlmodel":"b322cf6d7773bc3e7b79c56072d09a4ac8ad0ffc38262f34a27b1dace4e064a6",
    "Data/com.apple.CoreML/weights/weight.bin":"6f47f78fcc7054239bd1f9653b82179e622b0adff0c30877b495f62bf56c37bc",
}
def digest(path):
    sha=hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda:f.read(1024*1024),b""):
            sha.update(chunk)
    return sha.hexdigest()
for name,expected in FILES.items():
    path=ROOT/name
    if path.is_file() and digest(path)==expected: continue
    path.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent,delete=False) as f:
        tmp=Path(f.name)
    try:
        with urlopen(f"https://huggingface.co/apple/DepthPro2-coreml/resolve/{REV}/depthpro2-b_w4.mlpackage/{name}",timeout=180) as response, tmp.open("wb") as f:
            shutil.copyfileobj(response,f,1024*1024)
        if digest(tmp)!=expected: raise RuntimeError("SHA-256 divergente: "+name)
        os.replace(tmp,path)
    finally: tmp.unlink(missing_ok=True)
print("Base verificado (3 arquivos).")

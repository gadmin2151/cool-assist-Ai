#!/usr/bin/env python3
"""Fetch pinned official CPU runtimes. SHA-256 is verified before extraction."""
import argparse
import hashlib
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
ASSETS = {
    'win-x64': [
        ('whisper', 'https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-bin-x64.zip', '49dcc16de826f20bd53d44f947a1ae49dfa81f86cad67a64d80820cb192d674a'),
        ('llama', 'https://github.com/ggml-org/llama.cpp/releases/download/b10844/llama-b10844-bin-win-cpu-x64.zip', '3d9c64e0ee6fdb3218cefad5cab33cf4a54c797cd03725b42df74852edb01959'),
    ],
    'linux-x64': [
        ('whisper', 'https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-bin-ubuntu-x64.tar.gz', '46811a3ecf584307480a220b9ef5ff81b7b22dc41577cbc274ce3afc61f753b1'),
        ('llama', 'https://github.com/ggml-org/llama.cpp/releases/download/b10844/llama-b10844-bin-ubuntu-x64.tar.gz', '520bd0ee67e92d300029b8568e6478258d88dda77e8bb056f5936e5553871388'),
    ],
}


def fetch_vcredist():
    target = ROOT / 'runtime' / 'vc_redist.x64.exe'
    digest = 'cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b'
    url = 'https://download.visualstudio.microsoft.com/download/pr/bd1c8d9d-ba95-4eee-bc6e-df1fcc876373/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/VC_redist.x64.exe'
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == digest:
        return
    partial = target.with_suffix('.partial')
    subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--silent', '--show-error', '--max-time', '600', '--output', str(partial), url], check=True)
    if hashlib.sha256(partial.read_bytes()).hexdigest() != digest:
        partial.unlink()
        raise RuntimeError('Microsoft runtime checksum mismatch')
    partial.replace(target)


def fetch(platform):
    if platform == 'win-x64':
        fetch_vcredist()
    for name, url, digest in ASSETS[platform]:
        destination = ROOT / 'runtime' / platform / name
        receipt = destination / '.sha256'
        if receipt.exists() and receipt.read_text().strip() == digest:
            print(f'Verified runtime already prepared: {platform}/{name}')
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=destination.parent, prefix='download-') as temp:
            folder = pathlib.Path(temp)
            archive = folder / 'runtime'
            subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--connect-timeout', '30', '--max-time', '600', '--silent', '--show-error', '--output', str(archive), url], check=True)
            with archive.open('rb') as stream:
                actual = hashlib.file_digest(stream, 'sha256').hexdigest()
            if actual != digest:
                raise RuntimeError(f'Checksum mismatch: {platform}/{name}')
            unpacked = folder / 'unpacked'
            unpacked.mkdir()
            if url.endswith('.zip'):
                with zipfile.ZipFile(archive) as z:
                    for entry in z.infolist():
                        if not (unpacked / entry.filename).resolve().is_relative_to(unpacked.resolve()):
                            raise RuntimeError('Unsafe archive path')
                    z.extractall(unpacked)
            else:
                with tarfile.open(archive) as tar:
                    tar.extractall(unpacked, filter='data')
            if destination.exists():
                shutil.rmtree(destination)
            unpacked.rename(destination)
            receipt.write_text(digest + '\n')
            print(f'Prepared verified runtime: {platform}/{name}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=[*ASSETS, 'all'], default='all', nargs='?')
    selected = parser.parse_args().platform
    for platform in ASSETS if selected == 'all' else [selected]:
        fetch(platform)

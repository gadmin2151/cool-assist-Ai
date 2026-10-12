#!/usr/bin/env python3
"""Provision/reuse a stable personal signing identity; print only its certificate hash.

The private key is imported non-extractable into the login Keychain, available only
to codesign. No global certificate trust override is installed.
"""

import hashlib
import os
import secrets
from pathlib import Path
import subprocess
import tempfile

NAME = "Meet Protocol Personal Code Signing v1"
ROOT = Path(__file__).resolve().parent.parent
DIRECTORY = ROOT / ".tools" / "macos-signing"


def run(*args: str, input: bytes | None = None) -> bytes:
    result = subprocess.run(args, input=input, capture_output=True, check=False)
    if result.returncode:
        raise SystemExit(f"{Path(args[0]).name} {args[1]} failed (exit {result.returncode}): {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def main() -> None:
    os.umask(0o077)
    DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
    keychain = run("/usr/bin/security", "default-keychain", "-d", "user").decode().strip().strip('"')
    found = subprocess.run(
        ["/usr/bin/security", "find-certificate", "-a", "-c", NAME, "-p", keychain],
        capture_output=True, check=False,
    )
    if found.returncode not in (0, 44):
        raise SystemExit("Cannot read the signing certificate from Keychain; unlock it and retry.")
    certificate = found.stdout
    if certificate:
        if certificate.count(b"BEGIN CERTIFICATE") != 1:
            raise SystemExit("Multiple Meet Protocol signing certificates; select SIGN_IDENTITY explicitly.")
    else:
        if (DIRECTORY / "certificate.pem").exists():
            raise SystemExit("The saved signing identity is missing from Keychain. Restore it; refusing to rotate it silently.")
        with tempfile.TemporaryDirectory(prefix="meet-protocol-signing-") as temporary:
            folder = Path(temporary)
            config = folder / "openssl.cnf"
            config.write_text(f"""[req]
prompt = no
distinguished_name = subject
x509_extensions = signing
[subject]
CN = {NAME}
O = Meet Protocol Personal
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
            private_key = folder / "private.pem"
            public_cert = folder / "certificate.pem"
            package = folder / "identity.p12"
            run("/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072",
                "-nodes", "-sha256", "-days", "3650", "-config", str(config),
                "-keyout", str(private_key), "-out", str(public_cert))
            wrapping_password = secrets.token_urlsafe(32)
            run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(private_key),
                "-in", str(public_cert), "-name", NAME, "-passout", "stdin", "-out", str(package),
                input=(wrapping_password + "\n").encode())
            run("/usr/bin/security", "import", str(package), "-k", keychain,
                "-f", "pkcs12", "-P", wrapping_password, "-x", "-T", "/usr/bin/codesign")
            certificate = public_cert.read_bytes()
    der = run("/usr/bin/openssl", "x509", "-outform", "DER", input=certificate)
    identity = hashlib.sha1(der).hexdigest().upper()
    saved = DIRECTORY / "certificate.pem"
    if saved.exists():
        previous = run("/usr/bin/openssl", "x509", "-outform", "DER", input=saved.read_bytes())
        if previous != der:
            raise SystemExit("Signing certificate differs from the saved identity; refusing to rotate it silently.")
    saved.write_bytes(certificate)
    print(identity)


if __name__ == "__main__":
    main()

"""Local TLS server launcher. Pairing proof is generated locally, never exposed over HTTP."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import socket
import subprocess
import tempfile
from datetime import UTC, datetime, timedelta
from pathlib import Path
from urllib.parse import urlsplit

import httpx
import qrcode
import uvicorn
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from .api import create_app
from .config import BusinessConfig, Settings
from .db import Database


def private_directory(path: Path):
    path.mkdir(parents=True, exist_ok=True)
    if os.name == "nt":
        # Removing inheritance and granting only this user protects pairing/session state and keys.
        windows_tools = Path(os.environ["SystemRoot"]) / "System32"
        account = subprocess.run(  # noqa: S603 - fixed OS executable and argument array, no shell.
            [str(windows_tools / "whoami.exe")], capture_output=True, text=True, check=True
        ).stdout.strip()
        subprocess.run(  # noqa: S603 - current OS identity and a literal ACL, no shell interpolation.
            [
                str(windows_tools / "icacls.exe"),
                str(path),
                "/inheritance:r",
                "/grant:r",
                f"{account}:(OI)(CI)F",
            ],
            check=True,
            capture_output=True,
        )
    else:
        path.chmod(0o700)


def write_private(path: Path, data: bytes):
    path.write_bytes(data)
    if os.name != "nt":
        path.chmod(0o600)


def tls_material(runtime: Path, address: str) -> tuple[Path, Path, str]:
    key_path, cert_path = runtime / "tls-key.pem", runtime / "tls-cert.pem"
    regenerate = not (key_path.is_file() and cert_path.is_file())
    if not regenerate:
        try:
            certificate = x509.load_pem_x509_certificate(cert_path.read_bytes())
            san = certificate.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
            names = [
                str(value) for value in san.get_values_for_type(x509.IPAddress)
            ] + san.get_values_for_type(x509.DNSName)
            regenerate = address not in names or certificate.not_valid_after_utc <= datetime.now(
                UTC
            ) + timedelta(days=1)
        except ValueError:
            regenerate = True
    if regenerate:
        key = ec.generate_private_key(ec.SECP256R1())
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "ShelfSight local server")])
        sans = [x509.DNSName("localhost")]
        try:
            sans.append(x509.IPAddress(ipaddress.ip_address(address)))
        except ValueError:
            sans.append(x509.DNSName(address))
        certificate = (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(subject)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(datetime.now(UTC) - timedelta(minutes=5))
            .not_valid_after(datetime.now(UTC) + timedelta(days=90))
            .add_extension(x509.SubjectAlternativeName(sans), critical=False)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .sign(key, hashes.SHA256())
        )
        write_private(
            key_path,
            key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            ),
        )
        write_private(cert_path, certificate.public_bytes(serialization.Encoding.PEM))
    fingerprint = certificate.fingerprint(hashes.SHA256()).hex()
    return key_path, cert_path, fingerprint


def public_address(settings: Settings) -> str:
    if settings.public_address:
        value = settings.public_address.strip().rstrip("/")
        if "://" not in value:
            value = f"https://{value}:{settings.port}"
        parsed = urlsplit(value)
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username
            or parsed.password
            or parsed.path
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError(
                "SHELFSIGHT_PUBLIC_ADDRESS must be an HTTPS origin reachable from the phone"
            )
        return value
    # Best-effort discovery only; the user may override the displayed address in Settings.
    try:
        address = socket.gethostbyname(socket.gethostname())
    except OSError:
        address = "127.0.0.1"
    return f"https://{address}:{settings.port}"


def download_model(settings: Settings):
    if not settings.model_url or not settings.model_sha256 or not settings.model_path:
        raise ValueError("Set model URL, SHA256, and destination path before downloading")
    if (
        urlsplit(settings.model_url).scheme != "https"
        or len(settings.model_sha256) != 64
        or any(ch not in "0123456789abcdef" for ch in settings.model_sha256.lower())
    ):
        raise ValueError("Model download requires an HTTPS URL and SHA256 digest")
    settings.model_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        digest = hashlib.sha256()
        with tempfile.NamedTemporaryFile(dir=settings.model_path.parent, delete=False) as output:
            temporary = Path(output.name)
            with httpx.Client(timeout=60, follow_redirects=False) as client:
                with client.stream("GET", settings.model_url) as response:
                    response.raise_for_status()
                    for chunk in response.iter_bytes():
                        output.write(chunk)
                        digest.update(chunk)
        if digest.hexdigest().lower() != settings.model_sha256.lower():
            raise ValueError("Model checksum mismatch; existing model was preserved")
        temporary.replace(settings.model_path)
        print(f"Verified detector model saved to {settings.model_path}")
    finally:
        if temporary and temporary.exists():
            temporary.unlink()


def main():
    parser = argparse.ArgumentParser(description="ShelfSight paired local processing server")
    parser.add_argument(
        "--download-model", action="store_true", help="Download configured model and verify SHA256"
    )
    parser.add_argument(
        "--pairing-only",
        action="store_true",
        help="Generate fresh protected pairing artifacts without serving",
    )
    args = parser.parse_args()
    settings = Settings()
    if args.download_model:
        download_model(settings)
        return
    private_directory(settings.runtime_dir)
    address = public_address(settings)
    key_path, cert_path, fingerprint = tls_material(settings.runtime_dir, urlsplit(address).hostname)
    db = Database(settings.runtime_dir / "shelfsight.sqlite3")
    app = create_app(settings, db=db)
    secret, expires = app.state.sessions.issue_pairing()
    pairing = {
        "version": 1,
        "address": address,
        "fingerprint_sha256": fingerprint,
        "pairing_secret": secret,
        "expires_at": datetime.fromtimestamp(expires, UTC).isoformat().replace("+00:00", "Z"),
    }
    pairing_path, qr_path = settings.runtime_dir / "pairing.json", settings.runtime_dir / "pairing.png"
    write_private(pairing_path, json.dumps(pairing, indent=2).encode())
    qrcode.make(json.dumps(pairing, separators=(",", ":"))).save(qr_path)
    config = BusinessConfig(settings.config_path)
    print(f"ShelfSight HTTPS address: {address}")
    print(f"Certificate SHA256: {fingerprint}")
    print(f"Scan pairing QR: {qr_path}")
    print(
        f"Manual pairing details: {pairing_path} "
        f"(one use; expires in {config.data['limits']['pairing_ttl_seconds']} seconds)"
    )
    if not settings.supabase_url or not settings.supabase_publishable_key.get_secret_value():
        print("Supabase Auth is not configured. Pairing will reject requests until configured.")
    if args.pairing_only:
        return
    uvicorn.run(
        app,
        host=settings.host,
        port=settings.port,
        ssl_keyfile=str(key_path),
        ssl_certfile=str(cert_path),
        access_log=False,
        ws_max_size=config.data["limits"]["max_image_bytes"] * 4 // 3 + 65536,
        ws_max_queue=1,
        log_level="warning",
    )


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Import owner-provided release secrets into a job-local signing keychain."""
import base64
import hashlib
import os
import re
import ssl
from pathlib import Path
import secrets
import subprocess
import tempfile


def main():
    required = ("PANELCTL_SIGNING_P12_BASE64", "PANELCTL_SIGNING_P12_PASSWORD",
                "PANELCTL_SIGNING_IDENTITY", "PANELCTL_SIGNING_KEYCHAIN")
    if any(not os.environ.get(name) for name in required):
        raise SystemExit("Release signing secrets are missing; refusing ad-hoc release")
    identity = os.environ["PANELCTL_SIGNING_IDENTITY"]
    if len(identity) != 40 or any(c not in "0123456789abcdefABCDEF" for c in identity):
        raise SystemExit("Signing identity must be a 40-character certificate SHA-1")
    keychain = os.environ["PANELCTL_SIGNING_KEYCHAIN"]
    if Path(keychain).exists():
        raise SystemExit("Refusing to overwrite an existing signing keychain")
    password = secrets.token_hex(32)

    def security(*args):
        # Never print arguments: import/partition commands contain passwords.
        result = subprocess.run(["security", *args], capture_output=True)
        if result.returncode:
            raise SystemExit(f"security {args[0]} failed (output withheld)")
        return result.stdout.decode()

    with tempfile.TemporaryDirectory(prefix="panelctl-signing-") as directory:
        certificate = Path(directory) / "identity.p12"
        certificate.write_bytes(base64.b64decode(
            os.environ["PANELCTL_SIGNING_P12_BASE64"], validate=True))
        certificate.chmod(0o600)
        security("create-keychain", "-p", password, keychain)
        security("set-keychain-settings", "-lut", "21600", keychain)
        security("unlock-keychain", "-p", password, keychain)
        security("import", str(certificate), "-k", keychain,
                 "-P", os.environ["PANELCTL_SIGNING_P12_PASSWORD"],
                 "-T", "/usr/bin/codesign")
        security("set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                 "-s", "-k", password, keychain)
        identities = security("find-identity", "-p", "codesigning", keychain)
        if identity.upper() not in identities.upper():
            raise SystemExit("Imported keychain has no matching signing identity; check certificate/private-key export and fingerprint secret")
        valid = security("find-identity", "-v", "-p", "codesigning", keychain)
        if identity.upper() not in valid.upper():
            matching = next(line for line in identities.splitlines() if identity.upper() in line.upper())
            if "CSSMERR_TP_NOT_TRUSTED" not in matching:
                reasons = re.findall(r"CSSMERR_[A-Z_]+", matching)
                raise SystemExit(f"Imported signing identity is not valid for code signing: {', '.join(reasons) or 'unknown reason'}")
            # Only trust the exact configured public certificate, for code signing.
            # This importer runs on disposable CI runners; never export a private key.
            pem = security("find-certificate", "-p", keychain)
            der = ssl.PEM_cert_to_DER_cert(pem)
            if hashlib.sha1(der).hexdigest().upper() != identity.upper():
                raise SystemExit("Refusing to trust a certificate that does not match the configured fingerprint")
            public_certificate = Path(directory) / "signing-certificate.pem"
            public_certificate.write_text(pem)
            security("add-trusted-cert", "-r", "trustRoot", "-p", "codeSign",
                     "-k", keychain, str(public_certificate))
            valid = security("find-identity", "-v", "-p", "codesigning", keychain)
            if identity.upper() not in valid.upper():
                raise SystemExit("Signing identity remains invalid after code-signing-only trust")
        print("Configured signing identity is present and valid in the job keychain")


if __name__ == "__main__":
    main()

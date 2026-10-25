#!/usr/bin/env python3
"""Room-local NTLMv2 helper for Wine's documented ntlm_auth pipe protocol.

Lets programs in a Virtual room use Windows authentication between their own
processes (NegotiateStream, WCF, local HTTP) without a domain. No network
listener, Mac password, or authentication bypass: the acceptor verifies NTLMv2
proofs with pyspnego against an owner-only identity that is created on first use.
msv1_0 (patch 0013) only uses this helper for local targets; everything else
still goes to Samba's ntlm_auth.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import stat
import struct
import sys
import tempfile

IDENTITY_NAME = ".virtual/local-identity.json"
MAX_LINE = 16_384


def read_identity(path: Path) -> dict[str, str]:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise PermissionError("identity must be owned by the current user and mode 0600")
        if info.st_size > 4096:
            raise ValueError("oversized identity")
        with os.fdopen(fd, encoding="utf-8") as stream:
            fd = -1
            value = json.load(stream)
    finally:
        if fd != -1:
            os.close(fd)
    if value.get("version") != 1:
        raise ValueError("unsupported identity")
    for key in ("username", "domain", "password"):
        text = value.get(key)
        if not isinstance(text, str) or not text or len(text) > 256 or any(c in text for c in "\r\n\0:"):
            raise ValueError("invalid identity")
    if len(value["password"]) < 64:
        raise ValueError("room password lacks required entropy")
    return value


def initialize(prefix: Path, username: str, domain: str) -> Path:
    directory = prefix.resolve() / ".virtual"
    directory.mkdir(mode=0o700, exist_ok=True)
    info = directory.lstat()
    # Andere Werkzeuge legen den Ordner evtl. mit der Standard-umask an: eigenen Ordner schließen.
    if stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and info.st_mode & 0o077:
        os.chmod(directory, 0o700)
        info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise PermissionError("room identity directory must be owned by the current user and mode 0700")
    path = prefix.resolve() / IDENTITY_NAME
    if not (path.exists() or path.is_symlink()):
        # Write a complete file under a temporary name; link() fails if another
        # helper won the race, and then that identity is used.
        identity = {"version": 1, "username": username, "domain": domain, "password": secrets.token_hex(48)}
        temp = directory / f".local-identity-{os.getpid()}-{secrets.token_hex(4)}"
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump(identity, stream)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            try:
                os.link(temp, path)
            except FileExistsError:
                pass
        finally:
            temp.unlink(missing_ok=True)
    identity = read_identity(path)
    if identity["username"].casefold() != username.casefold() or identity["domain"].casefold() != domain.casefold():
        raise ValueError("existing identity belongs to a different room user")
    return path


class Helper:
    def __init__(self, identity: dict[str, str], protocol: str, username: str | None,
                 domain: str | None, cached: bool):
        import spnego
        self.spnego = spnego
        self.identity = identity
        self.server = protocol == "squid-2.5-ntlmssp"
        if protocol not in ("ntlmssp-client-1", "squid-2.5-ntlmssp"):
            raise ValueError("unsupported helper protocol")
        if username and username.casefold() != identity["username"].casefold():
            raise ValueError("user does not belong to this room")
        if domain and domain.casefold() != identity["domain"].casefold():
            raise ValueError("domain does not belong to this room")
        self.cached = cached
        self.password: str | None = None
        self.features: set[str] = set()
        self.context = None
        self.flags = 0
        self.failed = False
        self._store = None

    def close(self):
        if self._store is not None:
            self._store.close()
            self._store = None

    def _acceptor_credentials(self):
        # pyspnego's portable NTLM acceptor deliberately requires a credential
        # file. Use an already-unlinked, owner-only temporary file via this
        # process's fd namespace: even SIGKILL leaves no credential file behind.
        if self._store is None:
            self._store = tempfile.TemporaryFile(mode="w+b")
            text = self.identity["domain"] + ":" + self.identity["username"] + ":" + self.identity["password"] + "\n"
            self._store.write(text.encode("utf-8"))
            self._store.flush()
        self._store.seek(0)
        os.environ["NTLM_USER_FILE"] = f"/dev/fd/{self._store.fileno()}"

    def _context(self):
        spnego = self.spnego
        req = spnego.ContextReq.none
        if "NTLMSSP_FEATURE_SIGN" in self.features:
            req |= spnego.ContextReq.integrity
        if "NTLMSSP_FEATURE_SEAL" in self.features:
            req |= spnego.ContextReq.integrity | spnego.ContextReq.confidentiality
        principal = self.identity["domain"] + "\\" + self.identity["username"]
        if self.server:
            self._acceptor_credentials()
            return spnego.server(protocol="ntlm", options=spnego.NegotiateOptions.use_ntlm,
                                 context_req=req)
        password = self.password
        if password is None:
            if not self.cached:
                raise ValueError("client password required")
            password = self.identity["password"]
        return spnego.client(principal, password, hostname="localhost", service="host", protocol="ntlm",
                             options=spnego.NegotiateOptions.use_ntlm, context_req=req)

    def command(self, line: str) -> str:
        if self.failed:
            return "NA NT_STATUS_LOGON_FAILURE"
        command, _, data = line.partition(" ")
        try:
            if command == "OK":
                return "OK" if self.server or self.cached or self.password is not None else "PW"
            if command == "PW" and not self.server and self.context is None:
                self.password = base64.b64decode(data, validate=True).decode("utf-8")
                return "OK"
            if command == "SF" and self.context is None:
                self.features = set(data.split())
                return "OK"
            if command == "YR" and self.context is None:
                self.context = self._context()
                token = base64.b64decode(data, validate=True) if self.server else None
                output = self.context.step(token)
                if output is None:
                    raise ValueError("missing handshake token")
                return ("TT " if self.server else "YR ") + base64.b64encode(output).decode("ascii")
            if command in ("TT", "KK") and self.context is not None and not self.context.complete:
                if command != ("KK" if self.server else "TT"):
                    raise ValueError("unexpected handshake direction")
                token = base64.b64decode(data, validate=True)
                if self.server:
                    self._acceptor_credentials()
                output = self.context.step(token)
                authenticate = token if self.server else output
                if not self.context.complete or authenticate is None or len(authenticate) < 64:
                    raise ValueError("authentication incomplete")
                if authenticate[:12] != b"NTLMSSP\0\x03\0\0\0":
                    raise ValueError("invalid authentication token")
                self.flags = struct.unpack_from("<I", authenticate, 60)[0]
                if "NTLMSSP_FEATURE_SEAL" in self.features and not self.context.context_attr & self.spnego.ContextReq.confidentiality:
                    raise ValueError("required encryption was not negotiated")
                if self.server:
                    expected = self.identity["domain"] + "\\" + self.identity["username"]
                    if (self.context.client_principal or "").casefold() != expected.casefold():
                        raise ValueError("authenticated principal does not belong to this room")
                    return "AF " + expected
                return "KK " + base64.b64encode(output).decode("ascii")
            if command in ("GF", "GK") and self.context is not None and self.context.complete:
                if command == "GF":
                    return f"GF {self.flags:x}"
                key = self.context.session_key
                if len(key) != 16:
                    raise ValueError("invalid session key")
                return "GK " + base64.b64encode(key).decode("ascii")
            return "BH Invalid helper command or state"
        except Exception:
            self.failed = True
            return "NA NT_STATUS_LOGON_FAILURE"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--init-prefix", type=Path)
    parser.add_argument("--helper-protocol")
    parser.add_argument("--username")
    parser.add_argument("--domain")
    parser.add_argument("--use-cached-creds", action="store_true")
    parser.add_argument("--room-principal")
    args = parser.parse_args()
    if args.init_prefix:
        if not args.username or not args.domain:
            parser.error("initialization requires the Wine username and computer name")
        initialize(args.init_prefix, args.username, args.domain)
        print("Room-local identity configured (private credentials are never printed).")
        return 0
    try:
        path = Path(os.environ["VIRTUAL_LOCAL_AUTH_FILE"])
        if not path.exists() and args.room_principal and "\\" in args.room_principal:
            domain, _, username = args.room_principal.partition("\\")
            prefix = path.parent.parent
            if path != prefix / IDENTITY_NAME:
                raise ValueError("identity must live in <prefix>/.virtual")
            initialize(prefix, username, domain)
        identity = read_identity(path)
        os.environ.pop("NTLM_USER_FILE", None)
        os.environ["LM_COMPAT_LEVEL"] = "5"
        helper = Helper(identity, args.helper_protocol, args.username, args.domain, args.use_cached_creds)
        try:
            while line := sys.stdin.buffer.readline(MAX_LINE + 1):
                if len(line) > MAX_LINE or not line.endswith(b"\n"):
                    print("NA NT_STATUS_INVALID_PARAMETER", flush=True)
                    return 1
                reply = helper.command(line.decode("utf-8").rstrip("\r\n"))
                print(reply, flush=True)
            return 0
        finally:
            helper.close()
    except Exception:
        print("NA NT_STATUS_LOGON_FAILURE", flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

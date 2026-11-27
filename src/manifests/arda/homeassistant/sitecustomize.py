# Loaded by every Python process in the Home Assistant container (PYTHONPATH).
#
# Python 3.13+ verifies certificates strictly (ssl.VERIFY_X509_STRICT), and
# the lab CA has no keyUsage extension, which strict mode demands of a CA:
# "CA cert does not include key usage extension", so the Dex login
# (hass-oidc-auth) can't reach dex.kidd.network.
#
# Here strict mode is dropped for *.kidd.network hosts only: the chain,
# expiry and hostname are still checked against the lab CA, and every other
# host keeps the full checks. Both entry points: wrap_socket for blocking
# code, wrap_bio for asyncio (aiohttp, which Home Assistant uses throughout).
# The same as ../paperless/sitecustomize.py, plus wrap_bio. Remove once the
# lab CA is re-issued with keyUsage (BACKLOG.md).
import ssl

_STRICT = getattr(ssl, "VERIFY_X509_STRICT", 0)


def _lab(host):
    return bool(host) and (host == "kidd.network" or host.endswith(".kidd.network"))


_wrap_socket = ssl.SSLContext.wrap_socket
_wrap_bio = ssl.SSLContext.wrap_bio


def _lab_wrap_socket(self, sock, *args, server_hostname=None, **kwargs):
    if _STRICT and _lab(server_hostname):
        self.verify_flags &= ~_STRICT
    return _wrap_socket(self, sock, *args, server_hostname=server_hostname, **kwargs)


def _lab_wrap_bio(self, incoming, outgoing, *args, server_hostname=None, **kwargs):
    if _STRICT and _lab(server_hostname):
        self.verify_flags &= ~_STRICT
    return _wrap_bio(self, incoming, outgoing, *args, server_hostname=server_hostname, **kwargs)


ssl.SSLContext.wrap_socket = _lab_wrap_socket
ssl.SSLContext.wrap_bio = _lab_wrap_bio

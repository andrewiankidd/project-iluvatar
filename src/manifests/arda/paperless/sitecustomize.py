# Loaded by every Python process in the Paperless container (PYTHONPATH).
#
# Python 3.13+ verifies certificates strictly (ssl.VERIFY_X509_STRICT), and
# the lab CA has no keyUsage extension, which strict mode demands of a CA:
# "CA cert does not include key usage extension", so Paperless can't reach
# dex.kidd.network for the Dex login. Go and Node apps don't check this.
#
# Here strict mode is dropped for *.kidd.network hosts only: the chain,
# expiry and hostname are still checked against the lab CA, and every other
# host (a public mail server) keeps the full checks. Remove once the lab CA
# is re-issued with keyUsage (BACKLOG.md).
import ssl

_STRICT = getattr(ssl, "VERIFY_X509_STRICT", 0)
_wrap_socket = ssl.SSLContext.wrap_socket


def _lab_wrap_socket(self, sock, *args, server_hostname=None, **kwargs):
    if _STRICT and server_hostname and (
        server_hostname == "kidd.network" or server_hostname.endswith(".kidd.network")
    ):
        self.verify_flags &= ~_STRICT
    return _wrap_socket(self, sock, *args, server_hostname=server_hostname, **kwargs)


ssl.SSLContext.wrap_socket = _lab_wrap_socket

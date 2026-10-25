"""Local credentials, cryptographic proof and room isolation; no network listener."""
import base64
import os
from pathlib import Path
import tempfile
import unittest

from ntlm_auth import Helper, initialize, read_identity


class RoomAuthTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.path = initialize(self.root, 'test-user', 'VIRTUAL-TEST')
        self.identity = read_identity(self.path)
        self.helpers = []
        os.environ['LM_COMPAT_LEVEL'] = '5'

    def tearDown(self):
        for helper in self.helpers:
            helper.close()
        os.environ.pop('NTLM_USER_FILE', None)
        self.temp.cleanup()

    def helper(self, server=False, identity=None):
        helper = Helper(identity or self.identity,
                        'squid-2.5-ntlmssp' if server else 'ntlmssp-client-1', None, None, True)
        self.helpers.append(helper)
        self.assertEqual(helper.command('SF NTLMSSP_FEATURE_SIGN NTLMSSP_FEATURE_SEAL'), 'OK')
        return helper

    def handshake(self, client, server, mutate=False):
        negotiate = client.command('YR').split(' ', 1)[1]
        challenge = server.command('YR ' + negotiate)
        self.assertTrue(challenge.startswith('TT '))
        authenticate = client.command(challenge)
        self.assertTrue(authenticate.startswith('KK '))
        if mutate:
            token = bytearray(base64.b64decode(authenticate.split(' ', 1)[1]))
            # Change the NTLMv2 response proof, keeping the token structurally valid.
            offset = int.from_bytes(token[24:28], 'little')
            token[offset] ^= 1
            authenticate = 'KK ' + base64.b64encode(token).decode()
        return server.command(authenticate)

    def test_identity_permissions_and_reuse(self):
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.path.parent.stat().st_mode & 0o777, 0o700)
        initialize(self.root, 'test-user', 'VIRTUAL-TEST')
        self.assertEqual(read_identity(self.path), self.identity)

    def test_identity_isolation(self):
        other = self.root / 'other'; other.mkdir()
        value = read_identity(initialize(other, 'test-user', 'VIRTUAL-TEST'))
        self.assertNotEqual(value['password'], self.identity['password'])
        self.assertEqual(self.handshake(self.helper(identity=value), self.helper(server=True)), 'NA NT_STATUS_LOGON_FAILURE')

    def test_wrong_password_rejected(self):
        client = self.helper()
        client.command('PW ' + base64.b64encode(b'incorrect-test-password').decode())
        self.assertEqual(self.handshake(client, self.helper(server=True)), 'NA NT_STATUS_LOGON_FAILURE')

    def test_tampered_proof_rejected(self):
        self.assertEqual(self.handshake(self.helper(), self.helper(server=True), mutate=True), 'NA NT_STATUS_LOGON_FAILURE')

    def test_positive_encrypted_bidirectional_exchange(self):
        client, server = self.helper(), self.helper(server=True)
        self.assertEqual(self.handshake(client, server), 'AF VIRTUAL-TEST\\test-user')
        self.assertEqual(client.command('GK'), server.command('GK'))
        self.assertTrue(client.context.context_attr & client.spnego.ContextReq.confidentiality)
        self.assertEqual(server.context.unwrap(client.context.wrap(b'ping').data).data, b'ping')
        self.assertEqual(client.context.unwrap(server.context.wrap(b'pong').data).data, b'pong')

    def test_key_unavailable_before_proof(self):
        self.assertTrue(self.helper().command('GK').startswith('BH '))

    def test_malformed_token_fails_closed(self):
        helper = self.helper(server=True)
        self.assertEqual(helper.command('YR invalid!'), 'NA NT_STATUS_LOGON_FAILURE')
        self.assertEqual(helper.command('YR '), 'NA NT_STATUS_LOGON_FAILURE')

    def test_wrong_principal_rejected(self):
        with self.assertRaises(ValueError):
            Helper(self.identity, 'ntlmssp-client-1', 'other-user', None, True)
        with self.assertRaises(ValueError):
            initialize(self.root, 'other-user', 'VIRTUAL-TEST')

    def test_unsafe_identity_rejected(self):
        self.path.chmod(0o644)
        with self.assertRaises(PermissionError): read_identity(self.path)
        self.path.unlink()
        self.path.symlink_to('/dev/null')
        with self.assertRaises(OSError): read_identity(self.path)


if __name__ == '__main__':
    unittest.main()

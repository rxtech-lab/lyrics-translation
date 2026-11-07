import hashlib
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('resolver', Path(__file__).with_name('resolve-signing-identity.py'))
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)

class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.fingerprint = hashlib.sha1(b'certificate').hexdigest().upper()
        self.profile = {'DeveloperCertificates': [b'certificate'], 'TeamIdentifier': ['TEAM']}

    def test_selects_profile_certificate_over_other_identity(self):
        identities = f'1) {"A" * 40} "Developer ID Application: Other (TEAM)"\n2) {self.fingerprint} "Developer ID Application: Company (TEAM)"'
        self.assertEqual(resolver.resolve(self.profile, identities), self.fingerprint)

    def test_rejects_missing_private_key_or_untrusted_certificate(self):
        with self.assertRaises(ValueError):
            resolver.resolve(self.profile, '0 valid identities found')

    def test_rejects_wrong_certificate_team_or_type(self):
        for fingerprint, name in [('A' * 40, 'Developer ID Application: Company (TEAM)'),
                                  (self.fingerprint, 'Developer ID Application: Company (OTHER)'),
                                  (self.fingerprint, 'Apple Development: Company (TEAM)')]:
            with self.subTest(name=name, fingerprint=fingerprint), self.assertRaises(ValueError):
                resolver.resolve(self.profile, f'1) {fingerprint} "{name}"')

if __name__ == '__main__':
    unittest.main()

"""Select a usable Developer ID identity authorized by the installed profile."""
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def resolve(profile, identities):
    allowed = {hashlib.sha1(cert).hexdigest().upper() for cert in profile['DeveloperCertificates']}
    team = profile['TeamIdentifier'][0]
    for fingerprint, name in re.findall(r'([A-Fa-f0-9]{40}) "([^"\n]+)"', identities):
        if (fingerprint.upper() in allowed and name.startswith('Developer ID Application: ')
                and name.endswith(f'({team})')):
            return fingerprint.upper()
    raise ValueError('No valid Developer ID signing identity matches the provisioning profile. '
                     'BUILD_CERTIFICATE_BASE64 must contain a profile-authorized certificate '
                     'and its private key; also check certificate expiry and trust.')


def main():
    profile = plistlib.loads(Path(sys.argv[1]).read_bytes())
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    identity = resolve(profile, identities)
    with open(os.environ['GITHUB_ENV'], 'a') as output:
        output.write(f'SIGNING_CERTIFICATE_NAME={identity}\n')
    print('Resolved a valid Developer ID signing identity authorized by the provisioning profile.')


if __name__ == '__main__':
    try:
        main()
    except ValueError as error:
        sys.exit(f'::error::{error}')

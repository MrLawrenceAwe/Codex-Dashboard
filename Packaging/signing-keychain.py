#!/usr/bin/env python3
"""Prepare the optional, isolated local build-signing keychain.

Its generated password stays in a private local file and is passed to security
on stdin, never in process arguments, environment variables, or build output.
"""
import argparse
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys

SUPPORT = Path.home() / 'Library/Application Support/Codex Dashboard/build-signing'
PASSWORD_FILE = SUPPORT / 'keychain-password'
KEYCHAIN = Path.home() / 'Library/Keychains/codex-dashboard-build.keychain-db'


def security_command(*arguments):
    command = ' '.join(shlex.quote(str(argument)) for argument in arguments) + '\n'
    result = subprocess.run(['/usr/bin/security', '-i'], input=command,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode or 'SecKeychain' in result.stderr or 'SecItem' in result.stderr:
        # Interactive security output can echo its input, which contains a secret.
        raise RuntimeError(f'security {arguments[0]} failed; secret output suppressed')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--create', action='store_true')
    parser.add_argument('--authorize-signing', action='store_true')
    parser.add_argument('--run', nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.run is not None:
        if not arguments.run:
            raise RuntimeError('--run requires a command')
        selected = os.environ.get('SIGNING_KEYCHAIN')
        previous = shlex.split(subprocess.check_output(
            ['/usr/bin/security', 'list-keychains', '-d', 'user'], text=True))
        try:
            if selected and selected not in previous:
                subprocess.run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *previous, selected], check=True)
            result = subprocess.run(arguments.run, timeout=60)
        finally:
            if selected and selected not in previous:
                subprocess.run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *previous], check=True)
        sys.exit(result.returncode)
    if not PASSWORD_FILE.exists() and not arguments.create:
        return
    SUPPORT.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(SUPPORT, 0o700)
    if not PASSWORD_FILE.exists():
        if KEYCHAIN.exists():
            raise RuntimeError('Build keychain already exists without its password file; leaving it untouched')
        descriptor = os.open(PASSWORD_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(secrets.token_hex(32))
    os.chmod(PASSWORD_FILE, 0o600)
    password = PASSWORD_FILE.read_text().strip()
    if not password:
        raise RuntimeError('Build keychain password file is empty')
    if not KEYCHAIN.exists():
        previous_search = subprocess.check_output(['/usr/bin/security', 'list-keychains', '-d', 'user'], text=True)
        search_paths = shlex.split(previous_search)
        previous_default = shlex.split(subprocess.check_output(['/usr/bin/security', 'default-keychain', '-d', 'user'], text=True))
        try:
            security_command('create-keychain', '-p', password, KEYCHAIN)
        finally:
            # Keep the user's default and search list unchanged.
            subprocess.run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *search_paths], check=True)
            if previous_default:
                subprocess.run(['/usr/bin/security', 'default-keychain', '-d', 'user', '-s', previous_default[0]], check=True)
        if not KEYCHAIN.exists():
            raise RuntimeError('Build keychain creation failed')
        os.chmod(KEYCHAIN, 0o600)
    security_command('unlock-keychain', '-p', password, KEYCHAIN)
    if arguments.authorize_signing:
        security_command('set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, KEYCHAIN)
    else:
        print(KEYCHAIN)


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.SubprocessError, RuntimeError) as error:
        print(f'Build signing keychain: {error}', file=sys.stderr)
        sys.exit(1)

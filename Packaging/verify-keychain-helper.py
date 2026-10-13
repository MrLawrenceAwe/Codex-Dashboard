#!/usr/bin/env python3
"""Exercise the helper with a disposable item, never saved-account credentials."""
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SIGNING_ENV = os.environ.copy()
if not SIGNING_ENV.get("SIGNING_KEYCHAIN"):
    SIGNING_ENV["SIGNING_KEYCHAIN"] = subprocess.check_output(
        ["python3", str(ROOT / "Packaging/signing-keychain.py")], text=True).strip()
if SIGNING_ENV["SIGNING_KEYCHAIN"] == str(Path.home() / "Library/Keychains/codex-dashboard-build.keychain-db"):
    subprocess.run(["python3", str(ROOT / "Packaging/signing-keychain.py"), "--authorize-signing"], check=True)
IDENTITY = subprocess.check_output(
    ["/bin/zsh", str(ROOT / "Packaging/signing-identity.sh")], text=True, env=SIGNING_ENV
).strip()

RUNNER = r'''
import Foundation
let helper = CommandLine.arguments[1]
let request = FileHandle.standardInput.readDataToEndOfFile()
let child = Process()
let input = Pipe()
let output = Pipe()
child.executableURL = URL(fileURLWithPath: helper)
child.standardInput = input
child.standardOutput = output
child.standardError = FileHandle.nullDevice
try child.run()
try output.fileHandleForWriting.close()
try input.fileHandleForReading.close()
try input.fileHandleForWriting.write(contentsOf: request)
try input.fileHandleForWriting.close()
let response = output.fileHandleForReading.readDataToEndOfFile()
child.waitUntilExit()
guard child.terminationStatus == 0 else { exit(child.terminationStatus) }
try FileHandle.standardOutput.write(contentsOf: response)
'''


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, timeout=60)


def sign(path, identifier=None):
    args = ["codesign", "--force", "--sign", IDENTITY]
    if SIGNING_ENV["SIGNING_KEYCHAIN"]:
        args = ["python3", str(ROOT / "Packaging/signing-keychain.py"), "--run", *args,
                "--keychain", SIGNING_ENV["SIGNING_KEYCHAIN"]]
    if identifier:
        args += ["--identifier", identifier]
    subprocess.run([*args, str(path)], check=True, capture_output=True, timeout=60, env=SIGNING_ENV)


def cdhash(path):
    result = run("codesign", "-dv", "--verbose=4", str(path))
    return next(line for line in result.stderr.decode().splitlines() if line.startswith("CDHash="))


with tempfile.TemporaryDirectory(prefix="codex-keychain-helper-test-") as temporary:
    folder = Path(temporary)
    app = folder / "Dashboard Probe.app"
    executable = app / "Contents/MacOS/Probe"
    helper = app / "Contents/Helpers/CodexDashboardKeychainHelper"
    executable.parent.mkdir(parents=True)
    helper.parent.mkdir(parents=True)
    (app / "Contents/Resources").mkdir()
    with (app / "Contents/Info.plist").open("wb") as file:
        plistlib.dump({"CFBundleIdentifier": "local.lawrenceawe.codex-dashboard",
                      "CFBundleExecutable": "Probe", "CFBundlePackageType": "APPL"}, file)
    source = folder / "Probe.swift"
    source.write_text(RUNNER)
    run("swiftc", "-O", str(source), "-o", str(executable))
    shutil.copy2(ROOT / ".build/release/CodexDashboardKeychainHelper", helper)
    sign(helper, "local.lawrenceawe.codex-dashboard.keychain-helper")
    sign(app)
    run("codesign", "--verify", "--deep", "--strict", str(app))
    account = str(uuid.uuid4())

    def request(operation, interaction=False, account_id=None, requires_authorization=False):
        data = {"operation": operation, "accountID": account_id or account, "probe": True,
                "interactionAllowed": interaction}
        if operation == "store":
            data["credential"] = "ZGlzcG9zYWJsZS1oZWxwZXItdGVzdA=="
        result = subprocess.run([str(executable), str(helper)], input=json.dumps(data).encode(),
                                capture_output=True, check=True, timeout=20)
        response = json.loads(result.stdout)
        if requires_authorization:
            assert response["authorizationRequired"] or response["status"] in (-25308, -25293, -128), f"Protected access did not fail closed: status={response['status']}, authorizationRequired={response['authorizationRequired']}, hasCredential={response.get('credential') is not None}"
            assert response.get("credential") is None, "Protected credential was returned"
            return
        assert response["status"] == 0 and not response["authorizationRequired"], "Keychain access failed"
        return response.get("credential")

    before_parent = cdhash(app)
    before_helper = cdhash(helper)
    try:
        request("store")
        assert request("read") == "ZGlzcG9zYWJsZS1oZWxwZXItdGVzdA=="
        (app / "Contents/Resources/changed-build.txt").write_text("Changed dashboard build")
        sign(app)
        run("codesign", "--verify", "--deep", "--strict", str(app))
        assert cdhash(app) != before_parent, "Parent build hash did not change"
        assert cdhash(helper) == before_helper, "Helper build hash changed"
        assert request("read") == "ZGlzcG9zYWJsZS1oZWxwZXItdGVzdA=="
        request("store")
        assert request("read") == "ZGlzcG9zYWJsZS1oZWxwZXItdGVzdA=="
        unauthorized = subprocess.run([str(helper)], input=b"{}", capture_output=True, timeout=10)
        assert unauthorized.returncode == 77 and not unauthorized.stdout, "Unsigned caller was accepted"
        # A disposable item trusted only by security must not open an approval
        # dialog when the helper reads it in the background. The default ACL
        # permits updates; those must remain silent without granting read access.
        restricted_account = str(uuid.uuid4()).upper()
        run("security", "add-generic-password", "-a", restricted_account,
            "-s", "com.lawrenceawe.CodexDashboard.helper-probe",
            "-w", "disposable-restricted-test", "-T", "/usr/bin/security")
        try:
            request("read", account_id=restricted_account, requires_authorization=True)
            request("store", account_id=restricted_account)
            request("read", account_id=restricted_account, requires_authorization=True)
        finally:
            run("security", "delete-generic-password", "-a", restricted_account,
                "-s", "com.lawrenceawe.CodexDashboard.helper-probe")
        print("PASS: changed caller build; unchanged helper; silent read/write; protected reads rejected before and after silent update; unsigned caller rejected.")
    finally:
        request("delete", interaction=True)

#!/usr/bin/env python3
"""
Interactive Transmission proxy setup for the selfHosted Jellyfin stack.

Prompts for proxy type, host, port, and optional credentials, then writes
TRANSMISSION_PROXY_URL to jellyfin/.env and proxy_url in Transmission settings.

Usage:
  python3 configureTransmissionProxy.py
  sudo python3 configureTransmissionProxy.py   # also updates system settings + restart

After changing .env only, re-apply with:
  sudo ./applyTransmission.sh --force
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse, urlunparse

SCRIPT_DIR = Path(__file__).resolve().parent
ENV_FILE = SCRIPT_DIR / ".env"
SETTINGS_TEMPLATE = SCRIPT_DIR / "transmissionDaemon.settings.example.json"
USER_SETTINGS = Path.home() / ".config/transmission-daemon/settings.json"
SYSTEM_SETTINGS = Path("/var/lib/transmission/.config/transmission-daemon/settings.json")
TRANSMISSION_USER = "transmission"

PROXY_SCHEMES = ("socks5h", "socks5", "http", "https", "socks4h", "socks4")
ENV_KEY = "TRANSMISSION_PROXY_URL"


class ProxyConfig:
    def __init__(
        self,
        enabled: bool,
        scheme: str = "socks5h",
        host: str = "",
        port: int = 1080,
        username: str = "",
        password: str = "",
    ) -> None:
        self.enabled = enabled
        self.scheme = scheme
        self.host = host
        self.port = port
        self.username = username
        self.password = password

    @property
    def proxyUrl(self) -> str | None:
        if not self.enabled:
            return None
        userInfo = ""
        if self.username:
            user = quote(self.username, safe="")
            pwd = quote(self.password, safe="")
            userInfo = f"{user}:{pwd}@" if self.password else f"{user}@"
        netloc = f"{userInfo}{self.host}:{self.port}"
        return urlunparse((self.scheme, netloc, "", "", "", ""))

    @classmethod
    def fromProxyUrl(cls, proxyUrl: str | None) -> ProxyConfig:
        if not proxyUrl or not proxyUrl.strip():
            return cls(enabled=False)
        parsed = urlparse(proxyUrl.strip())
        scheme = parsed.scheme or "socks5h"
        host = parsed.hostname or ""
        port = parsed.port or 1080
        username = parsed.username or ""
        password = parsed.password or ""
        return cls(
            enabled=True,
            scheme=scheme,
            host=host,
            port=port,
            username=username,
            password=password,
        )


def printStep(message: str) -> None:
    print(f"\n{message}")


def printInfo(message: str) -> None:
    print(f"  {message}")


def promptLine(label: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    while True:
        raw = input(f"{label}{suffix}: ").strip()
        if raw:
            return raw
        if default:
            return default
        print("  (required — enter a value or press Ctrl+C to quit)")


def promptInt(label: str, default: int) -> int:
    while True:
        raw = input(f"{label} [{default}]: ").strip()
        if not raw:
            return default
        try:
            value = int(raw)
            if 1 <= value <= 65535:
                return value
        except ValueError:
            pass
        print("  Enter a port number between 1 and 65535.")


def promptYesNo(label: str, defaultYes: bool = True) -> bool:
    defaultHint = "Y/n" if defaultYes else "y/N"
    while True:
        raw = input(f"{label} [{defaultHint}]: ").strip().lower()
        if not raw:
            return defaultYes
        if raw in ("y", "yes"):
            return True
        if raw in ("n", "no"):
            return False
        print("  Answer y or n.")


def promptScheme(defaultScheme: str = "socks5h") -> str:
    printStep("Proxy type (socks5h recommended — DNS through proxy):")
    for index, scheme in enumerate(PROXY_SCHEMES, start=1):
        marker = " (default)" if scheme == defaultScheme else ""
        print(f"  {index}) {scheme}{marker}")
    while True:
        raw = input(f"Choice [1-{len(PROXY_SCHEMES)}] or scheme name [{defaultScheme}]: ").strip().lower()
        if not raw:
            return defaultScheme
        if raw.isdigit():
            choice = int(raw)
            if 1 <= choice <= len(PROXY_SCHEMES):
                return PROXY_SCHEMES[choice - 1]
        if raw in PROXY_SCHEMES:
            return raw
        print(f"  Pick 1–{len(PROXY_SCHEMES)} or one of: {', '.join(PROXY_SCHEMES)}")


def validateHost(host: str) -> bool:
    if not host:
        return False
    if host in ("localhost", "127.0.0.1", "::1"):
        return True
    if re.fullmatch(r"[a-zA-Z0-9.-]+", host):
        return True
    return bool(re.fullmatch(r"[0-9a-fA-F:.]+", host))


def readEnvFile(envPath: Path) -> dict[str, str]:
    if not envPath.is_file():
        return {}
    values: dict[str, str] = {}
    for line in envPath.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        values[key.strip()] = value.strip()
    return values


def writeEnvVar(envPath: Path, key: str, value: str | None) -> None:
    lines: list[str] = []
    found = False
    if envPath.is_file():
        for line in envPath.read_text(encoding="utf-8").splitlines():
            if line.strip().startswith(f"{key}="):
                found = True
                if value is not None:
                    lines.append(f"{key}={value}")
                continue
            lines.append(line)

    if not found and value is not None:
        if lines and lines[-1].strip():
            lines.append("")
        lines.append(f"# Transmission tracker/web proxy (configureTransmissionProxy.py)")
        lines.append(f"{key}={value}")

    envPath.parent.mkdir(parents=True, exist_ok=True)
    envPath.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def loadSettingsJson(settingsPath: Path) -> dict[str, Any]:
    if settingsPath.is_file():
        return json.loads(settingsPath.read_text(encoding="utf-8"))
    if SETTINGS_TEMPLATE.is_file():
        return json.loads(SETTINGS_TEMPLATE.read_text(encoding="utf-8"))
    return {"proxy_url": None}


def applyProxyToSettings(settingsPath: Path, proxyUrl: str | None) -> None:
    data = loadSettingsJson(settingsPath)
    data["proxy_url"] = proxyUrl
    settingsPath.parent.mkdir(parents=True, exist_ok=True)
    settingsPath.write_text(json.dumps(data, indent=4) + "\n", encoding="utf-8")


def transmissionDaemonRunning() -> bool:
    if not shutil.which("transmission-remote"):
        return False
    try:
        subprocess.run(
            ["transmission-remote", "--session-info"],
            capture_output=True,
            check=True,
            timeout=5,
        )
        return True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return False


def restartTransmissionDaemon() -> bool:
    if os.geteuid() != 0:
        printInfo("Skipping restart — run with sudo to restart transmission-daemon.")
        return False
    try:
        subprocess.run(["systemctl", "restart", "transmission-daemon"], check=True, timeout=30)
        subprocess.run(
            ["transmission-remote", "--session-info"],
            capture_output=True,
            check=True,
            timeout=10,
        )
        printInfo("transmission-daemon restarted and RPC is reachable.")
        return True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        printInfo(f"Restart issue: {exc}")
        return False


def chownSystemSettings() -> None:
    if os.geteuid() != 0 or not SYSTEM_SETTINGS.is_file():
        return
    subprocess.run(
        ["chown", "-R", f"{TRANSMISSION_USER}:{TRANSMISSION_USER}", str(SYSTEM_SETTINGS.parent)],
        check=False,
    )


def collectProxyConfig(currentUrl: str | None) -> ProxyConfig:
    current = ProxyConfig.fromProxyUrl(currentUrl)
    if current.enabled:
        printStep("Current proxy")
        printInfo(f"{current.scheme}://{current.host}:{current.port}")
        if current.username:
            printInfo(f"Username: {current.username}")

    printStep("Transmission download proxy")
    printInfo("Routes tracker and web traffic through your proxy.")
    printInfo("For full peer anonymity, use a VPN — proxy_url alone is not enough.")

    enabled = promptYesNo("Enable proxy for Transmission?", defaultYes=current.enabled)
    if not enabled:
        return ProxyConfig(enabled=False)

    scheme = promptScheme(current.scheme if current.enabled else "socks5h")

    defaultHost = current.host if current.enabled else "127.0.0.1"
    while True:
        host = promptLine("Proxy host", defaultHost)
        if validateHost(host):
            break
        print("  Enter a hostname or IP address.")

    defaultPort = current.port if current.enabled else (1080 if scheme.startswith("socks") else 8080)
    port = promptInt("Proxy port", defaultPort)

    useAuth = promptYesNo("Proxy requires username/password?", defaultYes=bool(current.username))
    username = ""
    password = ""
    if useAuth:
        username = promptLine("Username", current.username if current.username else "")
        password = promptLine("Password", current.password if current.password else "")

    return ProxyConfig(
        enabled=True,
        scheme=scheme,
        host=host,
        port=port,
        username=username,
        password=password,
    )


def confirmApply(config: ProxyConfig) -> bool:
    printStep("Summary")
    if not config.enabled:
        printInfo("Proxy: disabled (proxy_url cleared)")
    else:
        displayUrl = config.proxyUrl or ""
        if config.username and config.password:
            displayUrl = re.sub(
                r"://([^:@/]+):([^@/]+)@",
                r"://\1:***@",
                displayUrl,
            )
        elif config.username:
            displayUrl = re.sub(r"://([^:@/]+)@", r"://\1:***@", displayUrl)
        printInfo(f"Proxy URL: {displayUrl}")
    printInfo(f"Env file:  {ENV_FILE}")
    printInfo(f"Settings:  {SYSTEM_SETTINGS if os.geteuid() == 0 else USER_SETTINGS}")
    return promptYesNo("Apply these settings?", defaultYes=True)


def applyConfig(config: ProxyConfig) -> None:
    proxyUrl = config.proxyUrl

    if proxyUrl is None:
        writeEnvVar(ENV_FILE, ENV_KEY, None)
        printInfo(f"Removed {ENV_KEY} from {ENV_FILE}")
    else:
        writeEnvVar(ENV_FILE, ENV_KEY, proxyUrl)
        printInfo(f"Updated {ENV_KEY} in {ENV_FILE}")

    applyProxyToSettings(USER_SETTINGS, proxyUrl)
    printInfo(f"Updated {USER_SETTINGS}")

    if os.geteuid() == 0:
        applyProxyToSettings(SYSTEM_SETTINGS, proxyUrl)
        chownSystemSettings()
        printInfo(f"Updated {SYSTEM_SETTINGS}")
    else:
        printInfo(f"System settings not updated — re-run with sudo or: sudo ./applyTransmission.sh --force")

    if promptYesNo("Restart transmission-daemon now?", defaultYes=True):
        if not transmissionDaemonRunning() and os.geteuid() != 0:
            printInfo("Daemon may not be running. Use: sudo systemctl restart transmission-daemon")
        restartTransmissionDaemon()


def parseArgs() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Configure Transmission proxy for selfHosted.")
    parser.add_argument(
        "--disable",
        action="store_true",
        help="Disable proxy without prompts (still updates .env and settings).",
    )
    return parser.parse_args()


def main() -> int:
    args = parseArgs()

    if not ENV_FILE.is_file() and not SETTINGS_TEMPLATE.is_file():
        print(f"Expected jellyfin/.env or {SETTINGS_TEMPLATE.name} beside this script.", file=sys.stderr)
        return 1

    envValues = readEnvFile(ENV_FILE)
    currentUrl = envValues.get(ENV_KEY)
    if not currentUrl and USER_SETTINGS.is_file():
        try:
            currentUrl = loadSettingsJson(USER_SETTINGS).get("proxy_url")
        except json.JSONDecodeError:
            pass

    print("Transmission proxy setup (selfHosted / Apeksha)")
    print("=" * 48)

    if args.disable:
        config = ProxyConfig(enabled=False)
    else:
        try:
            config = collectProxyConfig(currentUrl if isinstance(currentUrl, str) else None)
        except KeyboardInterrupt:
            print("\nCancelled.")
            return 130

    if not args.disable and not confirmApply(config):
        print("No changes made.")
        return 0

    applyConfig(config)
    printStep("Done")
    printInfo("Apeksha uses local RPC only — no proxy needed on the backend.")
    printInfo("Re-apply paths anytime: sudo ./applyTransmission.sh --force")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

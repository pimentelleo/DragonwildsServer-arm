# DragonwildsServer-arm

Install and operate a [RuneScape: Dragonwilds](https://dragonwilds.runescape.com/)
dedicated server on an ARM64 Linux host.

The official Linux dedicated-server build is x86_64 only. This project downloads
the official dedicated-server app with native ARM64
[DepotDownloader](https://github.com/SteamRE/DepotDownloader), builds a private
[Box64](https://github.com/ptitSeb/box64) ARM dynarec runtime, and manages the
server with systemd. It does not install SteamCMD, register global `binfmt_misc`
handlers, or modify firewall rules.

> [!WARNING]
> This is an unsupported x86_64-on-ARM64 deployment. Box64 adds CPU overhead
> compared with an x86_64 host. Test the server with your expected player count
> before relying on it for a long-running public world.

## What the installer creates

| Path | Purpose |
| --- | --- |
| `/opt/dragonwilds` | Game files, DepotDownloader, and the private Box64 runtime |
| `/etc/dragonwilds/world-password` | Root-readable copy of the generated private-world password |
| `/var/lib/dragonwilds` | Box64 cache and systemd service state |
| `dragonwilds.service` | Dedicated systemd service, run as the `dragonwilds` system user |

Worlds, game configuration, and logs remain under
`/opt/dragonwilds/RSDragonwilds/Saved`.

## Requirements

- Ubuntu or Debian-family ARM64 Linux with `systemd` and `apt`
- A 64-bit ARM host; 4 KiB memory pages are recommended for Box64
- A public or routed UDP path for players, if the server will be reachable from
  the Internet
- A 17-digit SteamID64 for the account that will own the world
- At least 8 GiB of free disk space and sufficient RAM for the intended player
  count

The installer installs its build and download dependencies with `apt`. It uses
the free Steam dedicated-server app **4019830** through anonymous
DepotDownloader login.

## Install

Clone the repository and run the interactive installer:

```bash
git clone https://github.com/pimentelleo/DragonwildsServer-arm.git
cd DragonwildsServer-arm
sudo ./install.sh
```

It asks for:

1. The owner's 17-digit SteamID64.
2. A server name and world name.
3. A private-world password. Leaving it blank generates a cryptographically
   random password.

The password is never printed by the installer. Retrieve it locally when
needed:

```bash
sudo cat /etc/dragonwilds/world-password
```

For unattended setup, provide the owner ID explicitly. Names use safe defaults
and a private password is generated automatically:

```bash
sudo ./install.sh --non-interactive --owner-id 7656119XXXXXXXXXX
```

To supply a chosen password without placing it in shell history, put it in a
root-readable file and pass its path:

```bash
sudo ./install.sh \
  --owner-id 7656119XXXXXXXXXX \
  --world-password-file /root/dragonwilds-password
```

The service starts automatically after installation. The first boot can take
longer while Unreal Engine and Box64 initialize.

## Network access

The default game endpoint is:

| Direction | Protocol | Port |
| --- | --- | ---: |
| Player to server | UDP | 7777 |

Open or forward the same UDP port in both the host firewall and the cloud
network security layer. For Oracle Cloud, this normally means an ingress rule
in the relevant Network Security Group or Security List plus a public IP or
other routed endpoint.

The installer intentionally makes **no** firewall changes because host and
cloud firewall ownership vary by environment.

Use a different port with:

```bash
sudo ./install.sh --port 7778
```

## Operations

`dwctl` prompts for `sudo` when required:

```bash
./dwctl status
./dwctl logs
./dwctl follow
./dwctl restart
./dwctl password
./dwctl update
```

You can also use systemd directly:

```bash
sudo systemctl status dragonwilds
sudo systemctl restart dragonwilds
sudo journalctl -u dragonwilds -f
```

### Updating

Update game files while preserving worlds and configuration:

```bash
sudo ./update.sh
```

The updater stops the service, downloads the current public server build,
restores required executable permissions, then restarts the service if it was
running. If the private ARM64 DepotDownloader executable is absent, the updater
restores it automatically before stopping the service.

To rebuild the private Box64 runtime from current upstream source, rerun:

```bash
sudo ./install.sh --rebuild-box64
```

### Changing server settings

Stop the service before editing the game configuration:

```bash
sudo systemctl stop dragonwilds
sudoedit /opt/dragonwilds/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini
sudo systemctl start dragonwilds
```

`OwnerId` is required by Dragonwilds for normal dedicated-server operation. It
identifies the Steam account that owns the world; it does not affect the
anonymous Steam download used by the installer.

## Uninstall

The default uninstaller removes the systemd service, password copy, and Box64
cache but preserves all server files and worlds:

```bash
sudo ./uninstall.sh
```

Deleting the installation and its worlds requires deliberate destructive flags:

```bash
sudo ./uninstall.sh --purge --delete-world
```

It does not remove packages installed through `apt` and never changes host or
cloud firewall rules.

## Architecture and performance

The service invokes Box64 directly:

```text
ARM64 Linux -> Box64 ARM dynarec -> x86_64 Dragonwilds dedicated server
```

This avoids global x86_64 execution handlers and keeps the emulator scoped to
this one service. Unlike a Java server, Dragonwilds does not require a JVM that
generates further x86_64 code at runtime, but its workload is still emulated.
CPU cost, memory use, and stability should be measured on the target host and
with real players.

## License

This repository is licensed under the [MIT License](LICENSE). Dragonwilds,
Box64, DepotDownloader, Steam, and their respective assets remain subject to
their own licenses and terms.

# 🐑 Herdr — Terminal Workspace Manager for AI Coding Agents

[Herdr](https://herdr.dev) runs your AI coding agents side by side in persistent workspaces, tabs and panes, and you can attach to them from anywhere, including your phone. 🚀✨

This folder covers how to **install Herdr** and how to get the **Herdr Mobile** Android app connected over SSH, including a fix for a zsh issue that stops the app finding your sessions. 📱

## 📁 Files

```text
herdr/
└── README.md                       # 👈 You are here
```

## 🧩 Supported Platforms

- 🐧 Linux: `x86_64` and `aarch64`
- 🍎 macOS: Intel (`x86_64`) and Apple silicon (`aarch64`)
- 🪟 Windows: `x86_64`. Windows ARM64 runs the x86_64 build under emulation.

## ⚡ Quick Install

### 🐧 Linux / 🍎 macOS

```bash
curl -fsSL https://herdr.dev/install.sh | sh
herdr
```

### 🪟 Windows (PowerShell)

```powershell
powershell -ExecutionPolicy Bypass -c "irm https://herdr.dev/install.ps1 | iex"
herdr
```

If endpoint security blocks the PowerShell command, use **Command Prompt** instead:

```cmd
curl.exe -fsSLo install.cmd https://herdr.dev/install.cmd && install.cmd && del install.cmd
herdr
```

## 📦 Package Managers

```bash
# 🍺 Homebrew
brew install herdr

# 🧰 mise (if mise says herdr isn't in its registry, update mise first)
mise use -g herdr
mise use -g github:herdrdev/herdr      # temporary fallback

# ❄️ Nix (replace v0.x.y with a release tag)
nix run github:herdrdev/herdr/v0.x.y
nix profile install github:herdrdev/herdr/v0.x.y
```

> 💡 Package-manager installs update through their own package manager, **not** through `herdr update`.

## 🛠️ Manual Install (Linux / macOS)

Download the binary for your platform from the [GitHub releases](https://github.com/herdrdev/herdr/releases):

| Platform | Asset |
|---|---|
| 🐧 Linux x86_64 | `herdr-linux-x86_64` |
| 🐧 Linux aarch64 | `herdr-linux-aarch64` |
| 🍎 macOS Intel | `herdr-macos-x86_64` |
| 🍎 macOS Apple silicon | `herdr-macos-aarch64` |
| 🪟 Windows x86_64 | `herdr-windows-x86_64.zip` |

Then make it executable and put it on your `PATH`:

```bash
chmod +x herdr-linux-x86_64
mkdir -p ~/.local/bin
mv herdr-linux-x86_64 ~/.local/bin/herdr
```

> 🪟 On Windows, extract the **whole** zip and keep `herdr.exe` next to its ConPTY runtime files. Don't copy only the `.exe`.

## ✅ Verify

```bash
herdr --version
herdr status
```

## 🚀 First Launch

Run Herdr from a project directory. It creates a workspace automatically and shows onboarding on the first run:

```bash
cd ~/my-project
herdr
```

🐚 Optional shell completion (zsh):

```bash
mkdir -p ~/.zfunc
herdr completion zsh > ~/.zfunc/_herdr
```

Then make sure `~/.zshrc` adds the folder to `fpath` **before** `compinit` runs:

```zsh
fpath=(~/.zfunc $fpath)
autoload -Uz compinit && compinit
```

## 🔁 Update

```bash
herdr update                      # direct installs only
herdr update --handoff            # experimental: keep running servers via live handoff
herdr channel set preview         # opt into preview builds
herdr channel set stable          # back to stable (default)
```

By default `herdr update` leaves running servers alive. Restart Herdr to reconnect with the new client.

## 📱 Herdr Mobile (Android) Over SSH

The [Herdr Mobile](https://play.google.com/store/apps/details?id=dev.herdr.mobile) app connects **directly over SSH**, with no relay and no cloud account. After you log in, it:

1. 🔍 runs an environment probe (CPU type, bridge version, location of the `herdr` binary)
2. 📥 uploads `herdr-mobile-bridge` to `~/.local/bin/`, checking it against a SHA-256 checksum
3. 📋 lists your Herdr sessions with `herdr-mobile-bridge sessions --json`
4. 🔌 opens the session with `herdr-mobile-bridge stdio --session <name>`

### 🧾 Host Checklist

- 🔐 `sshd` is running and the phone can reach it (LAN, VPN, ZeroTier or Tailscale)
- 🐑 Herdr is running on the host (`~/.config/herdr/herdr.sock` exists)
- 📂 the `sftp` subsystem is enabled in `sshd` (Ubuntu enables it by default)
- 👤 you log in as the **same user** that runs Herdr

```bash
systemctl is-active ssh
test -S ~/.config/herdr/herdr.sock && echo "herdr socket OK ✅"
```

## 🩺 Troubleshooting

### ❌ "无法读取服务器上的 session 列表" / "Can't read the session list on the server"

The app says SSH connected but `herdr-mobile-bridge sessions --json` returned nothing usable, and the bridge never shows up in `~/.local/bin/`.

#### 🔎 Cause 1: `herdr` isn't on the `PATH` for non-interactive SSH

The app runs commands over SSH exec, **not** an interactive login. With zsh as the login shell, only `~/.zshenv` is read, so `~/.local/bin` (where the installer puts `herdr`) is missing from `PATH`.

Check it:

```bash
env -i HOME=$HOME zsh -c 'command -v herdr || echo "herdr NOT on PATH ❌"'
```

#### 🔎 Cause 2: zsh stops the app's discovery script when a wildcard matches nothing

The app's discovery script is written for POSIX `sh` and loops over `~/.config/herdr/sessions/*/`. If you have no named sessions, that folder doesn't exist. `sh` just keeps the unmatched pattern and carries on, but zsh fails with `no matches found` and **stops the whole script** before it reports the `default` session.

Reproduce it:

```bash
zsh -c 'for d in ~/.config/herdr/sessions/*/; do :; done; echo herdr-discovery=done'
# zsh:1: no matches found: /home/you/.config/herdr/sessions/*/   ❌

sh -c 'for d in ~/.config/herdr/sessions/*/; do :; done; echo herdr-discovery=done'
# herdr-discovery=done   ✅
```

#### 🛠️ Fix

Back up `~/.zshenv` once, then add both lines. It's safe to re-run: the backup is only made the first time, and the lines are only added if they aren't already there.

```bash
touch ~/.zshenv
[ -e ~/.zshenv.bak-herdr-mobile ] || cp ~/.zshenv ~/.zshenv.bak-herdr-mobile

grep -q 'herdr-mobile: POSIX glob' ~/.zshenv || cat >> ~/.zshenv <<'EOF'
# 🐑 herdr-mobile: make herdr visible to non-interactive SSH
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$PATH:$HOME/.local/bin" ;; esac
# 🐑 herdr-mobile: POSIX glob behaviour, scoped to the app's commands only
if [[ -n ${SSH_CONNECTION-} && ! -o interactive && ${ZSH_EXECUTION_STRING-} == *herdr-mobile-bridge* ]]; then unsetopt NOMATCH NULL_GLOB CSH_NULL_GLOB; fi
EOF

zsh -n ~/.zshenv && echo "syntax OK ✅"
```

- 🧷 `~/.local/bin` is **appended** to `PATH`, so it can't override system commands.
- 🎯 The glob change only applies to non-interactive SSH commands that mention `herdr-mobile-bridge`. Your normal shell and other scripts keep zsh's default behaviour.

Then tap **重试 / Retry** in the app. It should install the bridge and list your `default` session. 🎉

```bash
~/.local/bin/herdr-mobile-bridge --version   # → herdr-mobile-bridge 0.3.1
```

#### 🕵️ Still Failing? Log What the App Runs

Temporarily log every non-interactive SSH command to see exactly which step fails. The log goes in a private file in your home directory, readable only by you:

```bash
install -m 600 /dev/null ~/.herdr-mobile-ssh.log
echo '[[ -n $SSH_CONNECTION && ! -o interactive ]] && print -r -- "$(date +%T) [$$] ${ZSH_EXECUTION_STRING:-<no command>}" >> ~/.herdr-mobile-ssh.log  # TEMP herdr-mobile debug' >> ~/.zshenv
```

Tap **Retry**, then read `~/.herdr-mobile-ssh.log`. When you're done, **remove the debug line and the log**. It records every SSH command:

```bash
# 🐧 Linux (GNU sed)
sed -i '/TEMP herdr-mobile debug/d' ~/.zshenv; rm -f ~/.herdr-mobile-ssh.log

# 🍎 macOS (BSD sed)
sed -i '' '/TEMP herdr-mobile debug/d' ~/.zshenv; rm -f ~/.herdr-mobile-ssh.log
```

> 🔒 Optional hardening: `chmod 755 ~/.local/bin`. The bridge runs from there, so it shouldn't be group- or world-writable.

## 🧹 Undo the Mobile Fix

```bash
mv ~/.zshenv.bak-herdr-mobile ~/.zshenv
```

## 🔗 References

- 🌐 Herdr: <https://herdr.dev>
- 📖 Install docs: <https://herdr.dev/docs/install/>
- 🐙 Source and releases: <https://github.com/herdrdev/herdr>
- 📱 Herdr Mobile: <https://play.google.com/store/apps/details?id=dev.herdr.mobile>

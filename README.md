# WndSwitcher

A small macOS menu-bar app that switches between the windows of the app you are currently using, with <kbd>Option</kbd> + <kbd>`</kbd>.

## Usage

| Shortcut | Action |
| --- | --- |
| <kbd>⌥</kbd> <kbd>`</kbd> | Next window of the focused app |
| <kbd>⇧</kbd> <kbd>⌥</kbd> <kbd>`</kbd> | Previous window of the focused app |

Repeated presses walk through all of the app's windows in a fixed order. Minimized windows are skipped.

### First launch

WndSwitcher needs the Accessibility permission to raise other apps' windows.

1. Launch the app. macOS prompts for Accessibility access.
2. Open System Settings → Privacy & Security → Accessibility and switch WndSwitcher on. This command jumps straight to that page:

   ```bash
   open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
   ```

3. Press <kbd>⌥</kbd> <kbd>`</kbd> in any app with two or more windows.

### Menu-bar item

WndSwitcher has no Dock icon. Click its icon in the menu bar for:

- **Version** — the app version and build number.
- **Enabled** — turns switching on or off. While off, the shortcuts are released and the icon is dimmed. The setting is remembered across launches.
- **Accessibility** — shows whether the permission is granted; click it to open the settings page.
- **Launch at Login** — starts WndSwitcher when you log in. Move the app to `/Applications` before turning this on.
- **Quit WndSwitcher**

### Good to know

- While WndSwitcher is enabled, <kbd>⌥</kbd> <kbd>`</kbd> no longer types the grave-accent dead key (used for è, à, …). Turn **Enabled** off to get it back.
- If another app has already claimed <kbd>⌥</kbd> <kbd>`</kbd>, the menu shows "⌥` is taken by another app".

## Build from source

### Requirements

- macOS 13 or later
- Xcode or the Xcode Command Line Tools (`xcode-select --install`), for `swiftc` and `codesign`

### Build

```bash
./build.sh
```

This compiles `Sources/main.swift` and produces `build/WndSwitcher.app`. To build, stop any running copy and launch the new one:

```bash
./build.sh --run
```

To install, copy `build/WndSwitcher.app` to `/Applications`.

### Code signing and the Accessibility permission

macOS ties the Accessibility permission to the app's code signature. By default `build.sh` signs ad hoc, and an ad-hoc signature changes on every build, so the permission must be granted again after each rebuild (remove the old WndSwitcher entry from the Accessibility list, then add the new build).

To make the permission survive rebuilds, create a self-signed code-signing certificate named `WndSwitcher Local Signing` once. `build.sh` uses it automatically when it exists in your keychain.

```bash
NAME="WndSwitcher Local Signing"
TMP="$(mktemp -d)" && cd "$TMP"
cat > cfg <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config cfg -keyout key.pem -out cert.pem
PW="$(uuidgen)"
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -out id.p12 -passout "pass:$PW"
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P "$PW" -T /usr/bin/codesign
cd - && rm -rf "$TMP"
```

The certificate shows as "not trusted" in Keychain Access; that is expected and does not affect signing. After the first build signed with it, grant Accessibility one more time. To remove the certificate, delete `WndSwitcher Local Signing` in Keychain Access.

### Project layout

| Path | Purpose |
| --- | --- |
| `Sources/main.swift` | The whole app: hotkey registration, window cycling, menu-bar item |
| `Info.plist` | Bundle metadata, including the version shown in the menu |
| `build.sh` | Compiles, bundles and signs the app |
| `build/` | Build output |

### Changing the version

Edit `CFBundleShortVersionString` (version) and `CFBundleVersion` (build number) in `Info.plist`, then rebuild.

## How it works

- The shortcuts are registered with Carbon's `RegisterEventHotKey`, which needs no permission of its own.
- Windows are listed and raised through the Accessibility API (`AXUIElement`), which is why the Accessibility permission is required.

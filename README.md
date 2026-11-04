# Bose Switcher

A macOS menu bar app for Bose QuietComfort Ultra Headphones (2nd Gen). Connect or disconnect paired devices, see what is playing, and check the battery.

![Bose Switcher panel showing battery and connection states](docs/panel.png)

Device names are blurred for privacy.

## Requirements

- A Mac running macOS 27 or later.
- Apple's Command Line Tools with Swift and the macOS 27 SDK or later.
- Bose QuietComfort Ultra Headphones (2nd Gen), paired with the Mac. Other models are untested.
- The devices you want to switch between must already be paired with the headphones.

No third-party packages or app account are needed.

## Install from source

1. Open Terminal (press Command-Space and search for Terminal). Install Apple's build tools:

   ```sh
   xcode-select --install
   ```

   Finish the installer before continuing. If the tools are already installed, skip this step.

2. Check the selected SDK:

   ```sh
   xcrun --sdk macosx --show-sdk-version
   ```

   It must report **27 or later**. If it reports an older version, update the Command Line Tools through **System Settings → General → Software Update**.

3. On this repository's GitHub page, choose **Code → Download ZIP**. Double-click the ZIP in Finder to extract it. A Git clone also works.

4. In Terminal, type `cd ` (with a space), drag the extracted folder from Finder into Terminal, and press Return.

5. Quit any running copy of Bose Switcher using **Quit** in its menu bar panel, then run:

   ```sh
   ./build.sh
   open "$HOME/Applications/Bose Switcher.app"
   ```

The script builds for your Mac, applies a local ad-hoc signature, and replaces the app in `~/Applications`. It needs no `sudo` or paid Apple developer account. The app has no Dock icon.

The app is not notarized by Apple. Downloaded ZIPs can carry a quarantine flag. If Gatekeeper blocks the app because Apple cannot verify it, try opening it once, then choose **System Settings → Privacy & Security → Open Anyway**. Only do this for source you trust. See [Apple's guide](https://support.apple.com/102445).

## First run

1. Allow Bluetooth access when macOS asks. If you denied it, enable Bose Switcher in **System Settings → Privacy & Security → Bluetooth**, then reopen the app.
2. Connect the headphones to the Mac in **System Settings → Bluetooth** once to load their paired devices.
3. Click the headphones-and-arrows menu bar icon. Click a connected device to disconnect it, or another device to connect it.

Blue icons mark connected devices. Rows show **Playing**, **Connected**, or switch progress. This Mac appears first. The panel stays open during a switch. Click outside it or click the icon again to close it.

## Start at login

Open **System Settings → General → Login Items & Extensions** (**Login Items** on some versions). Under **Open at Login**, click **+**, press Command-Shift-G, and enter `~/Applications`. Select **Bose Switcher.app** and click **Add**. The app does not add itself. See [Apple's guide](https://support.apple.com/guide/mac-help/mh15189/mac).

## Update

Quit the app, download and extract the latest source (or run `git pull --ff-only` in your clone), then repeat install steps 4 and 5. Your saved devices stay in place. There is no automatic updater.

## Uninstall

1. Quit the app and remove it from **Open at Login** if you added it.
2. In Finder, choose **Go → Go to Folder**, enter `~/Applications`, and move **Bose Switcher.app** to the Trash.
3. Remove its saved devices and settings in Terminal:

   ```sh
   defaults delete io.github.boseswitcher.app
   ```

If Terminal says the domain was not found, there were no saved settings. This does not unpair your headphones or other devices.

## How it works

The app uses Bose's private BMAP protocol over Bluetooth RFCOMM channel 2. It checks connection states every two seconds while the panel is open. Device names and addresses stay in local app preferences; there is no cloud service or telemetry.

When the Mac is disconnected, the panel shows saved devices without live states or battery. Clicking a row can connect the Mac to send the command. The app then tries to release that temporary connection, unless you chose to connect this Mac.

## Limits

- The headphones allow [two active connections](https://support.bose.com/article/quietcomfort-ultra-headphones-2nd-gen-connecting-a-bluetooth-device). Connecting a third can drop another device, including when the Mac connects temporarily.
- Switching can take several seconds or time out. Wear the headphones when connecting devices; they may refuse connections while off-head.
- Firmware changes may break the undocumented protocol.
- The app remembers the first paired headphones it finds with a BMAP service. There is no headphone picker.
- Only one app can use the control channel at a time. Quit Bose Switcher before using `bosectl`.

## Troubleshooting

| Problem | What to try |
| --- | --- |
| Build fails | Check `xcrun --sdk macosx --show-sdk-version`. Install or select build tools with the macOS 27 SDK or later. |
| Bluetooth access is blocked | Enable the app under **Privacy & Security → Bluetooth**. After an update, macOS may ask again. |
| No devices appear | Pair and connect the headphones to this Mac in Bluetooth settings, then reopen the panel. |
| “Not connected to this Mac” | Connect the Mac in Bluetooth settings to restore live states and battery. Cached rows can still send commands. |
| “Couldn't connect” or “No answer” | Check that the target is nearby, Bluetooth is on, and the headphones are worn. Quit other BMAP clients before trying again. |

## Development

```sh
bash Tests/check.sh
```

This compiles the app, runs behavior checks with fake Bluetooth devices, validates the plist and build script, and removes its temporary files. It does not install or launch the app or use Bluetooth hardware. See [CONTRIBUTING.md](CONTRIBUTING.md) for hardware testing and bug reports.

## Credits and license

Protocol research by [bosectl](https://github.com/aaronsb/bosectl) made this app possible.

Released under the [MIT License](LICENSE).

Bose Switcher is not affiliated with or endorsed by Bose Corporation. Bose and QuietComfort are trademarks of Bose Corporation.

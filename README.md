# Bose Switcher

A macOS 27 menu bar app that switches the devices connected to Bose QC Ultra Headphones (2nd Gen). Firmware 8.2.20 removed switching from the power button.

Click the headphones with the swap-arrows badge to open the glass panel. It follows design E: the headphones' name and battery above one list, with this Mac first and the remaining devices in their established order. Blue circles mean connected. The status below a name says Playing or Connected. Names omit the possessive owner prefix unless that would leave a blank or duplicate label. Tooltips and accessibility keep the full name.

Click a connected device to disconnect it, or another device to connect it. The panel stays open. An animated arc and Connecting… or Disconnecting… show progress on the row. A refusal shows Couldn't connect (or Couldn't disconnect) and beeps. A timeout shows No answer. Errors clear after three seconds. Quit also supports ⌘Q.

When the Mac is disconnected, the panel shows a note and last known devices without connection states or battery. Those rows still work. Rows are native SwiftUI buttons with accessibility names and state values for AXPress.

## Build

Requires macOS 27 and the macOS 27 SDK in the Xcode command line tools.

```sh
./build.sh
open ~/Applications/"Bose Switcher.app"
```

The build script compiles every root Swift file, signs the app and installs it into `~/Applications`. It replaces the installed copy, so quit that copy before building. Local ad-hoc signatures change when the executable changes, so macOS may ask for Bluetooth permission again after rebuilding. The app waits for permission before starting Bluetooth work and keeps device actions disabled until Bluetooth is ready.

To compile and check behavior without installing, launching the app or opening Bluetooth connections:

```sh
bash Tests/check.sh
```

This compiles into a temporary folder, runs packet, state, queue, coordinator and artwork checks, validates the plist and build script, then deletes the folder.

## How it works

The app uses Bose's private BMAP protocol on one RFCOMM channel (2), as reverse-engineered by [bosectl](https://github.com/aaronsb/bosectl). DeviceManagement commands are ListDevices `[4.4]`, Info `[4.5]`, Connect `[4.1]` with `00 + MAC`, and Disconnect `[4.2]` with `MAC`. Battery GET `[2.2]` reads the first response byte as a percentage, following [bosectl's parser](https://github.com/aaronsb/bosectl/blob/main/python/pybmap/devices/parsers.py). No cloud login is needed.

- A dedicated Bluetooth thread pumps the default run-loop mode, which IOBluetooth needs for data callbacks. UI state stays on the main thread.
- Actions take priority over queued refreshes. A refresh checks for queued actions every 20 ms while waiting for replies and yields. Jobs never run inside other jobs. Synchronous system Bluetooth calls cannot yield. An open RFCOMM channel sends its first request immediately.
- With cached devices, launch requests their Info together, then lists pairings at idle priority. Without a cache, it lists first. Battery shares the refresh channel without an extra reply wait.
- A connect completes on connected Info, and a remote disconnect completes on RESULT, not PROCESSING. Confirmation updates the row and unlocks clicks before refreshing or returning the Mac's temporary connection slot.
- If another action is already queued, it reuses the temporary Mac connection. Otherwise the app returns that temporary connection even after a failed read. Session cancellation releases a borrowed connection even when cancellation happens during opening. An explicit Mac disconnect confirms physical disconnection and honors refusals.
- Info replies merge by address as they arrive. Only one Info request per device can be outstanding. A missing reply or interrupted refresh closes the channel before another attempt, because BMAP has no request IDs. Timed-out commands also retire their channel, so their late replies cannot complete a retry.
- Complete pairing lists prune forgotten devices, retain addresses awaiting Info and establish ordering before rows arrive. The visible panel refreshes every two seconds and checks pairings every minute. An in-flight full list satisfies overlapping discovery requests. A discovery request during an Info refresh gets a follow-up list.
- Cached names remain available, but cached connection flags do not become live after a reconnect. Readings expire after five seconds, and unknown rows are checked before choosing a toggle action. The panel timer publishes expired readings even when no reply arrives. Bluetooth-off and sleep invalidate readings and reject work or callbacks from the previous session. Rows publish only when data or freshness changes, and data changes batch their cache writes.
- Confirmed state rejects contradictory Info requested within 2.5 seconds of confirmation, covering the measured firmware lag. Another background refresh runs after three seconds. Mac connectivity is tracked separately from device freshness.
- Connect polling checks throughout its pause, so late connected Info ends the wait immediately. A lost poll resumes on a new channel within the original deadline without repeating Connect. A cold channel gets three seconds for its first reply. Row actions expose idle, checking, working and failed states.
- The progress arc rotates in Core Animation. Closing the panel stops its animation, and Reduce Motion shows a still arc.
- Paired-device discovery runs only in the `--scan` child process because `IOBluetoothDevice.pairedDevices()` breaks connection checks in the calling process. The cached address is reused only while it remains paired. Forgetting it triggers discovery again, and selecting replacement headphones clears the old device cache.

## Hardware checks

Compilation and pure behavior checks do not verify the UI or Bluetooth. Before using this build:

- Compare default, connecting and Mac-disconnected panels against design E in light and dark mode. Check battery, the badge, fixed row order, ring, Reduce Motion, AXPress and ⌘Q.
- Launch with and without a device cache. Confirm fast cached Info, later pairing discovery, and that opening the panel never joins the headphones.
- Click during a slow list refresh. Check immediate progress and that the command gets the next turn.
- Connect a phone, disconnect a remote device, join this Mac and disconnect this Mac. Confirm results unlock clicks before refresh and do not flicker back during Info lag.
- Start from a disconnected Mac. Confirm the phone's result appears before the Mac gives back its slot. Click again immediately after confirmation.
- Check phone refusal, timeout, delayed or missing Info replies, link loss and a new pairing. Check the battery value against the headphones.

## Limits

- The headphones hold two connections. Connecting a third drops the one that is not playing.
- Phones take 6–17 seconds to join. The app cannot shorten that handshake.
- The headphones only connect devices while worn.
- A Mac that joins just to send a command leaves afterwards, even when the command fails. The explicit `openConnection()` is preserved. Self-disconnect waits for physical confirmation because the Mac receives no BMAP reply.
- Only one RFCOMM client per Mac can talk to the headphones. Quit Bose Switcher before running bosectl.
- The earlier Bluetooth behavior was tested on firmware 10.12.14. Successful remote switches, eviction and Mac self-disconnect still need validation while the headphones are worn.

# Bose Switcher

A macOS menu bar app that picks which device your Bose QC Ultra Headphones (2nd Gen) connect to. Firmware 8.2.20 removed device switching from the power button, and Bose says it won't bring it back.

Click the headphones icon to see every paired device. A check mark means connected, and "playing" marks the device the audio comes from. Click a device to connect it, or click a checked device to disconnect it. The Mac beeps when the headphones refuse.

## Build

```sh
./build.sh
open ~/Applications/"Bose Switcher.app"
```

It needs only the Xcode command line tools.

## How it works

The app talks to the headphones over Bose's private BMAP protocol on RFCOMM channel 2, as reverse-engineered by [bosectl](https://github.com/aaronsb/bosectl). It uses the DeviceManagement block: list devices `[4.4]`, device info `[4.5]`, connect `[4.1]` and disconnect `[4.2]`. None of these need Bose's cloud login.

## Limits

- The headphones hold 2 connections. Connecting a third drops the one that isn't playing.
- When the Mac isn't connected, a click makes the Mac join for a few seconds, send the command, then leave.
- The first menu open after the Mac connects takes about 3 seconds. The headphones answer the first request on a new link slowly.
- The headphones only connect devices while they're on your head.
- Only one app on the Mac can talk BMAP at a time, so quit this one before running bosectl.
- Tested on firmware 10.12.14.

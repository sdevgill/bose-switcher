# Contributing

Keep changes focused. For a bug report, include the macOS version, headphone model and firmware, steps to reproduce, and what you expected to happen. Remove personal names, device names, Bluetooth addresses, and local paths from logs and screenshots.

Run the checks before submitting a change:

```sh
bash Tests/check.sh
```

Add a focused check when changing behavior. Use fake devices and channels in automated tests; never let a test connect to real hardware. Use generic names such as “Phone” and “Computer” in fixtures.

Bluetooth and UI changes also need a manual check with your own hardware. Use `./build.sh` to install after quitting the app. Check light and dark appearance, connection progress, errors, and the disconnected state. Test only devices you control, and restore their connections afterwards. Run one Bluetooth control client at a time.

State what you tested in the pull request, including anything you could not verify. Keep Swift methods short and explain protocol quirks where they affect the code.

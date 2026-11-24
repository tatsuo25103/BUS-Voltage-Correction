# V0.8.1

**English** · [繁體中文](RELEASE_NOTES_V0.8.1.zh-TW.md)

## Reliability

- Disposes all temporary GDI pens, brushes and fonts used by the animated
  X CONTACTS gauge and BUS Error Trend chart.
- Pumps Windows messages while waiting for serial bytes so the Stop button
  remains responsive during communication timeouts.
- Cancels an active serial read immediately when the user stops calibration.
- Limits a single serial response to 4096 bytes to reject runaway or malformed
  frames.

## Communication safety

- Voltage fields must now contain only an optional sign and decimal digits.
  Text-contaminated or malformed fields are rejected instead of being converted
  into a voltage.
- GS and INGS telemetry responses must have a valid `^D` header.
- Correction commands are accepted only when the inverter returns `(ACK`.
- A failed manual correction clears every queued manual command so stale steps
  cannot run after communication is restored.

## Maintenance

- The production entry point is now `BUS_Voltage_Correction.ps1` with the
  version-independent launcher `open_desktop_gui.bat`.
- Added a portable ZIP with a hidden-console VBS launcher. It can run from a
  local folder or USB drive without installation or administrator permission.
- Added repeatable logic tests for parsing, inverter phase classification,
  target calculation, correction direction, gauge mapping, ACK handling and
  update version comparison.

## Validation

- PowerShell production and installer scripts parse without errors.
- 28 logic tests pass.
- Installer staging and clean per-user installation tests pass.
- Portable ZIP structure and clean extracted startup tests pass.
- Hardware communication and calibration still require a connected inverter
  validation before publishing this build.

Installer SHA-256:

```text
F70C0890AA12BEC2034BB89FD79BCC8A4B126B199B8C956072EE23674E8BC07E
```

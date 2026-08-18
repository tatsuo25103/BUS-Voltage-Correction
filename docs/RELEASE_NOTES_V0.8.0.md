# V0.8.0

**English** · [繁體中文](RELEASE_NOTES_V0.8.0.zh-TW.md)

## Inverter identification

- Added support for the FSP PowerManager Hybrid 5 kW single-phase calibration profile.
- Checks three consecutive AC input samples before boot commands or calibration writes.
- Prompts the user to confirm the 5 kW model only when VR is present and both VS and VT remain near zero.
- Uses `VR x 1.414` as the BUS target after single-phase confirmation.
- Keeps `max(VR, VS, VT) x 1.414` for a complete three-phase input.

## Safety

- Stops before calibration when exactly one AC phase is missing in three consecutive samples.
- Stops when the AC phase configuration cannot be identified safely instead of assuming three-phase operation.
- Accepts omitted or empty VS/VT fields from a single-phase GS response while retaining strict VR and INGS validation.
- Records the selected phase profile in the calibration report.

## Packaging

- Updated application, installer metadata and documentation to V0.8.0.
- Installer remains per-user and requires no Python or `pyserial` installation.
- The installer is not code-signed; Windows SmartScreen may display a warning.

## Validation

- PowerShell syntax and version-comparison tests passed.
- Single-phase, three-phase, missing-phase and unidentified-input classification tests passed.
- Clean per-user installation staging test passed.
- The 5 kW target calculation, readback fields and correction commands are based
  on the legacy 5 kW program that has been validated on multiple inverters.
- The new unified pre-boot auto-detection and confirmation flow has not yet been
  revalidated on a connected 5 kW inverter; verify its first field use from the
  phase-detection Event Log before broad deployment.

Installer SHA-256:

```text
CE61C0C6417739D23E96803B00E1FA4615F731EEC3B2ABD39B17285F9236EFCC
```

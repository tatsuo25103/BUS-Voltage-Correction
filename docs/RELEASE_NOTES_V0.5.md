# V0.5 Development Baseline

**English** · [繁體中文](RELEASE_NOTES_V0.5.zh-TW.md)

V0.5 is the preserved console-based development baseline that preceded the
current Windows GUI application. The original Python source is stored unchanged
under [`legacy/V0.5`](../legacy/V0.5/).

## Initial capabilities

- Automatic COM-port scan and inverter identity check.
- `2400 baud`, `8-N-1` serial communication.
- Inverter boot command followed by a fixed 60-second warm-up.
- BUS target calculated from `max(VR, VS, VT) x 1.414`.
- Sequential correction of VDSPP, VDSPN, VMCUP and VMCUN.
- Fixed 0.5 V correction commands and +/-5 V threshold.
- Basic ineffective-correction counter, console summary and text log.

## Development limitations

- Python and `pyserial` must be installed separately.
- No desktop GUI, installer, trend chart or X CONTACTS display.
- Opens serial ports for separate operations instead of maintaining one shared
  coordinated session.
- Uses one fixed 60-second warm-up rather than BUS-ready startup detection.
- Waits for all seven values together instead of independent channel stability.
- Corrects channels sequentially and does not perform two final verification
  windows.
- Does not include the current cumulative no-response, opposite-direction,
  report, manual queue or background-update safeguards.

## Status

This version is published as a **historical development pre-release**. It is
not the recommended service version. Use
[the latest release](https://github.com/tatsuo25103/BUS-Voltage-Correction/releases/latest)
for current work.

Original source SHA-256:

```text
88BB158E38B267099EC5F66BE27FEF999E731FA79534DCC0719DF7D7CABF560D
```

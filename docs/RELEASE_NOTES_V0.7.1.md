# V0.7.1

**English** · [繁體中文](RELEASE_NOTES_V0.7.1.zh-TW.md)

## User experience

- Added MES branding and packaged the required logo asset.
- Added a non-blocking GitHub Releases update check at startup.
- Update prompts wait until calibration, queued manual correction and safety
  dialogs are idle. Offline checks do not interrupt service work.

## Calibration and reporting

- Records each channel's first stable voltage immediately before its first
  automatic correction.
- Summary and reports distinguish the startup sample from stable pre-correction
  voltage.
- Unexpected failures attempt final readback and write a report with Event Log.
- Report-write failures cannot hide the original error or AC Grid-only reminder.
- Live state distinguishes `Ready`, `Running`, `Manual` and `Calibrating`.

## Controller behavior retained

- One coordinated serial connection is shared by all operations at `2400 baud`,
  `8-N-1`.
- Boot commands retry every 10 seconds until BUS voltage is ready.
- Four-channel stability is evaluated independently.
- Automatic correction uses a fixed 0.5 V step.
- Repeated ineffective, opposite or worsening response stops with a safety
  warning.
- Success requires two consecutive stable windows with all channels in range.
- Completion and failure reports include summary, steps and Event Log.

## Installer and validation

- Updated the per-user installer; Python and `pyserial` are not required.
- Clean temporary installation verified the application, launcher,
  documentation, uninstaller and logo.
- PowerShell parsing, version comparison and stable-value selection tests passed.
- GitHub release metadata and installer asset were verified after upload.
- No new live-inverter calibration was performed for this documentation update.

## Download

[Download V0.7.1](https://github.com/tatsuo25103/BUS-Voltage-Correction/releases/tag/v0.7.1)

Installer SHA-256:

```text
91855467912F1030C9A7B0D58844EEA1E636D6F467D49A32163B98B2733828D6
```

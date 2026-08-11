# BUS Voltage Correction V0.7.1

Windows desktop utility designed for FSP PowerManager Hybrid 10 kW and 15 kW inverters.

It monitors and calibrates the following inverter BUS voltage channels:

- VDSPP
- VDSPN
- VMCUP
- VMCUN

## Compatibility

- FSP PowerManager Hybrid 10 kW inverter
- FSP PowerManager Hybrid 15 kW inverter

## Installation

Run `BUS_Voltage_Correction_Setup_V0.7.1.exe`. The application is installed for the current Windows user and does not require Python.

The installer creates Desktop and Start Menu shortcuts. Use **Open Logs** in the application to open calibration reports and session logs.

At startup, the application checks GitHub Releases in the background. If a newer version is available, it offers to open the download page. Offline or failed checks do not interrupt operation.

## Calibration Safety

Before automatic calibration, disconnect AC Output, PV, BAT, and the parallel signal cable. Only AC Grid should remain connected.

## Data Location

Session logs and calibration reports are stored in:

```text
%LOCALAPPDATA%\BUS Voltage Correction\logs
```

## Requirements

- Windows 10 or Windows 11
- Available serial COM port
- Inverter communication at 2400 baud, 8-N-1

## Version

V0.7.1

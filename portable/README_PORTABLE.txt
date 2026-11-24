BUS Voltage Correction V0.8.1 - Portable Edition
================================================

Requirements
------------
- Windows 10 or Windows 11
- Correct USB-to-RS232 driver
- No Python installation is required
- No administrator permission is required

Start
-----
1. Extract the entire ZIP file to a local folder or USB drive.
2. Double-click "BUS Voltage Correction.vbs".
3. If Windows blocks VBS files, double-click "open_desktop_gui.bat" instead.

Do not run the application from inside the ZIP preview. Extract all files first
so the assets folder remains beside the application script.

Logs and calibration reports
----------------------------
Logs are stored in:

%LOCALAPPDATA%\BUS Voltage Correction\logs

Use the Open Logs button in the application to open this folder.

Safety
------
Before automatic calibration, disconnect AC Output, PV, BAT and the parallel
signal cable. Only AC Grid may remain connected.

This utility writes inverter calibration parameters and is intended for trained
service personnel.

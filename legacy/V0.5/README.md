# BUS Voltage Correction V0.5

Historical development baseline imported from the original source file dated
2025-02-18.

> **Development archive only.** V0.5 is a console-based prototype and is not
> recommended for current inverter service work. Use the latest supported
> Windows release instead.

## Contents

- `BUS_voltage_correctionV0.5.py`: original source preserved without changes.
- `requirements.txt`: Python dependency required by the original source.

## Original behavior

- scans serial ports for the supported inverter response;
- communicates at `2400 baud`, `8-N-1`;
- sends one boot sequence and then waits a fixed 60 seconds;
- calculates the target from the highest VR/VS/VT value multiplied by `1.414`;
- waits for all seven voltage readings to meet one shared stability condition;
- calibrates VDSPP, VDSPN, VMCUP and VMCUN sequentially;
- uses fixed 0.5 V commands and a fixed +/-5 V acceptance threshold;
- writes console output and `log_output.txt` in the working directory.

## Run for historical evaluation

```powershell
py -m pip install -r requirements.txt
py BUS_voltage_correctionV0.5.py
```

The USB-to-RS232 driver must already be installed. Before any hardware test,
disconnect AC Output, PV, BAT and the parallel signal cable; leave AC Grid only.

Original source SHA-256:

```text
88BB158E38B267099EC5F66BE27FEF999E731FA79534DCC0719DF7D7CABF560D
```

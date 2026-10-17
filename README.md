# ESP32 + MCP2517FD GVRET CAN FD adapter

Firmware for a tested NodeMCU ESP-32S / classic ESP32-D0WD-V3 board and an
MCP2517FD-family SPI CAN FD module. It exposes **one** CAN bus to SavvyCAN over
USB serial at **1,000,000 baud**. The current sketch reports build 7.

This is a hardware-specific project, not a universal MCP2517FD board profile.
The tested controller crystal is **20 MHz**; SPI is capped at **4 MHz**. The
default CAN configuration is 500 kbit/s arbitration and 2 Mbit/s FD data rate.

## Wiring

| ESP32 GPIO / supply | MCP2517FD module label | Purpose |
|---|---|---|
| GPIO18 | SCK | SPI clock |
| GPIO23 | SDI | SPI MOSI, ESP → module |
| GPIO19 | SDO | SPI MISO, module → ESP |
| GPIO5 | nCS | SPI chip select |
| GPIO21 | INT | Interrupt |
| GND | GND | Common signal/power ground |
| Regulated 3.3 V | 3V3 | 3.3 V logic domain — verify the actual module schematic |
| Regulated 5 V | 5V | 5 V transceiver domain — verify the actual module schematic |

The tested module's documentation requires **both 5 V and 3.3 V supplies with
a 3.3 V master**. Do not short its P2 jumper in this configuration: the
5 V-only/P2 option is for a 5 V master. Check your specific board before
applying power; module revisions may differ. Never connect automotive 12 V
directly to either board. Use a suitable protected automotive supply and a
proper CAN transceiver/termination arrangement. CAN-H and CAN-L connect to
the CAN network; this table only covers the ESP-to-module interface.

For a first desk test, power the ESP via USB and use a verified regulated 5 V
and 3.3 V arrangement for the module with common GND. Avoid feeding USB and
an external ESP VIN/5V source together without a proven power-selection
circuit. A CAN bench needs two 120 Ω terminations, one at each bus end.

## Build

From the repository root, using Arduino CLI and the ESP32 Arduino core:

```powershell
arduino-cli core install esp32:esp32@3.3.11
arduino-cli compile --fqbn esp32:esp32:nodemcu-32s --libraries .\libraries --build-path .\build\gvret .\firmware\esp32_mcp2517fd_gvret
```

The `libraries/ACAN2517FD` directory contains the exact 2.1.16 library copy
used for the tested build. Its MIT license and Pierre Molinaro's copyright
notice remain in [`libraries/ACAN2517FD/LICENSE`](libraries/ACAN2517FD/LICENSE).
The repository's top-level MIT license covers our firmware and bench scripts.
Generated `build/` files are deliberately not tracked by Git.

Only flash a board you have positively identified. For the same board/FQBN:

```powershell
arduino-cli upload -p COM4 --fqbn esp32:esp32:nodemcu-32s --input-dir .\build\gvret
```

Replace `COM4` with your actual port. Flashing replaces the previous program.
This repository's binary releases, if provided, are for the tested 4 MB ESP32
board profile; a merged flash image overwrites the target flash, including
existing settings.

## Protocol and behavior

- Classic CAN RX/TX and CAN FD RX/TX (up to 64 data bytes, with BRS).
- Standard and extended CAN identifiers, one local bus (`bus 0`). SavvyCAN may
  assign it a different **global** bus number.
- GVRET Classic frames use opcode `0x00`; the FD extension uses opcode `0x14`.
- Firmware defaults to **normal active mode** and can transmit/ACK when the
  bus is enabled. Select Listen Only before connecting to a network where
  transmission or ACK is not intended.
- FD setting/status extensions use commands `0x15`–`0x17`. FD-disabled mode is
  MCP2517FD Normal20B; enabling FD restores NormalFD.
- The FD serial extension was tested with a modified SavvyCAN build. Do not
  assume every upstream/older SavvyCAN binary understands FD opcode `0x14`.

## Validation and limits

On an isolated two-node bench with Vector VN1640A CH1, 600 mixed ESP → Vector
frames (200 Classic 8-byte, 200 FD 12-byte without BRS, 200 FD 64-byte with
BRS) were received byte-exact with zero loss, duplicates, Vector errors, or
ESP TEC/REC errors at about 100 frames/s. Listen Only blocked attempted TX;
FD-disabled mode blocked FD TX while Classic still worked. Earlier
Vector → ESP mixed-load and bidirectional tests also passed. The repeatable
Windows/Vector scripts are under `tools/` and require a separately installed
Vector driver/XL API; no Vector binaries are included.

This is **not** a certification for vehicle use, electrical fault tolerance,
or every SavvyCAN transmit feature. First test on an isolated, correctly
terminated bench. Never inject diagnostic or control frames into a vehicle
without understanding the target network and consequences.

## License

Our firmware, documentation and bench scripts: MIT, see [LICENSE](LICENSE).
Vendored ACAN2517FD 2.1.16: MIT, see its separate license above.

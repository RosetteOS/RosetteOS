# OpenKE Remote Display VNC Server (openke-vnc)

High-performance, lightweight Linux framebuffer VNC server and responsive HTML5 browser viewer for OpenKE (Ender 3 V3 SE / KE, Ingenic X2000 MIPS SoC).

## Features
- **Framebuffer Capture**: Directly memory-maps `/dev/fb0` with support for RGB565 and 32-bit pixel formats.
- **Dirty Region Tracking**: 32x32 tile difference hashing to transmit only changed screen regions (near zero CPU usage when idle).
- **Dual Protocols**:
  - **Standard VNC (RFB 3.8)**: Port `5900` for native VNC viewers (RealVNC, TigerVNC, Remmina, macOS Screen Sharing, etc.).
  - **Embedded Web VNC (noVNC)**: Port `5800` for zero-install direct browser access (`http://<printer-ip>:5800`).
- **Remote Input**: Supports remote touchscreen/mouse clicks, drags, and navigation keystrokes via `/dev/uinput`.
- **Ultra Lightweight**: Self-contained binary (<140 KB), <4 MB RAM usage.

## Build (Cross-compile for MIPS)

```sh
make
```

## Running on Target

```sh
./openke-vnc -p 5900 -w 5800
```

#!/usr/bin/env python3

# RosetteOS — reload the camera pipeline (S50webcam / ustreamer).
#
# USB/webcam stock-parity mission (2026-07-26): this script previously killed
# and relaunched Creality's own stock cam_app + mjpg_streamer binaries -
# leftover from before this project's own camera pipeline (pellcorp/
# k1-ustreamer, started/supervised by S50webcam) actually worked. Neither
# /usr/bin/cam_app nor /usr/bin/mjpg_streamer exist in this build at all, so
# the on-screen RELOAD_CAMERA button (GuppyScreen's useful-macros.cfg) did
# nothing useful for the real, running camera - it tried to start binaries
# that were never staged here, while leaving the actual ustreamer process
# it should have restarted completely untouched.
#
# S50webcam already runs a supervising loop that discovers the real UVC
# node and manages ustreamer's lifecycle (see its own header comment for
# why) - a plain restart of that init script is the correct, complete
# equivalent of "reload the camera" for this project's real pipeline.

import subprocess

S50WEBCAM = "/etc/init.d/S50webcam"


def main():
    subprocess.run([S50WEBCAM, "restart"], check=True)
    print("Camera pipeline reloaded")


if __name__ == "__main__":
    main()

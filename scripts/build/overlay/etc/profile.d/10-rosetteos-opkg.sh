#!/bin/sh
# RosetteOS Package Manager Environment Configuration
# Automatically adds /opt (Entware/opkg) and RosetteOS binaries and libraries to the environment.

if [ -d "/opt/bin" ]; then
    case ":$PATH:" in
        *":/opt/bin:"*) ;;
        *) export PATH="/opt/bin:/opt/sbin:/usr/data/rosetteos/bin:$PATH" ;;
    esac
fi

if [ -d "/opt/lib" ]; then
    case ":${LD_LIBRARY_PATH:-}:" in
        *":/opt/lib:"*) ;;
        *) export LD_LIBRARY_PATH="/opt/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
    esac
fi

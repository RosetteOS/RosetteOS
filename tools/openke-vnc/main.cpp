#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <csignal>
#include <unistd.h>
#include <chrono>
#include <thread>
#include "fb_device.h"
#include "uinput_injector.h"
#include "rfb_server.h"
#include "websocket_server.h"

static volatile bool g_running = true;

static void signal_handler(int sig) {
    (void)sig;
    g_running = false;
}

static void print_usage(const char* prog) {
    fprintf(stdout,
        "OpenKE Remote Display VNC Server v1.0.0\n"
        "Usage: %s [options]\n\n"
        "Options:\n"
        "  -p, --port <port>        VNC port for native VNC clients (default: 5900)\n"
        "  -w, --ws-port <port>     Web / WebSocket port for browser access (default: 5800)\n"
        "  -f, --fb <path>          Framebuffer device path (default: /dev/fb0)\n"
        "  -r, --fps <hz>           Target update rate in FPS (default: 30, max: 60)\n"
        "  -n, --name <name>        Desktop display name (default: OpenKE Remote Display)\n"
        "      --no-ws              Disable web/websocket server\n"
        "      --no-vnc             Disable standard VNC server\n"
        "  -h, --help               Show this help message\n",
        prog);
}

int main(int argc, char** argv) {
    uint16_t vnc_port = 5900;
    uint16_t ws_port = 5800;
    std::string fb_path = "/dev/fb0";
    uint32_t target_fps = 30;
    std::string desktop_name = "OpenKE Remote Display";
    bool enable_ws = true;
    bool enable_vnc = true;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if ((arg == "-p" || arg == "--port") && i + 1 < argc) {
            vnc_port = static_cast<uint16_t>(std::atoi(argv[++i]));
        } else if ((arg == "-w" || arg == "--ws-port") && i + 1 < argc) {
            ws_port = static_cast<uint16_t>(std::atoi(argv[++i]));
        } else if ((arg == "-f" || arg == "--fb") && i + 1 < argc) {
            fb_path = argv[++i];
        } else if ((arg == "-r" || arg == "--fps") && i + 1 < argc) {
            target_fps = static_cast<uint32_t>(std::atoi(argv[++i]));
            if (target_fps < 1) target_fps = 1;
            if (target_fps > 60) target_fps = 60;
        } else if ((arg == "-n" || arg == "--name") && i + 1 < argc) {
            desktop_name = argv[++i];
        } else if (arg == "--no-ws") {
            enable_ws = false;
        } else if (arg == "--no-vnc") {
            enable_vnc = false;
        } else if (arg == "-h" || arg == "--help") {
            print_usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown argument: %s\n", arg.c_str());
            print_usage(argv[0]);
            return 1;
        }
    }

    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);
    std::signal(SIGPIPE, SIG_IGN);

    fprintf(stdout, "=======================================================\n");
    fprintf(stdout, " OpenKE Remote Display VNC Server v1.0.0\n");
    fprintf(stdout, "=======================================================\n");

    FBDevice fb;
    if (!fb.open_device(fb_path)) {
        fprintf(stderr, "[Main] Error: Could not initialize framebuffer %s\n", fb_path.c_str());
        return 1;
    }

    UinputInjector injector;
    injector.init(fb.get_width(), fb.get_height());

    RfbServer rfb(fb, injector, vnc_port, desktop_name);
    if (enable_vnc) {
        if (!rfb.start()) {
            fprintf(stderr, "[Main] Error: Failed to start RFB server on port %u\n", vnc_port);
            return 1;
        }
    }

    WebSocketServer ws(rfb, ws_port);
    if (enable_ws) {
        if (!ws.start()) {
            fprintf(stderr, "[Main] Warning: Failed to start Web VNC on port %u\n", ws_port);
        }
    }

    fprintf(stdout, "-------------------------------------------------------\n");
    if (enable_vnc) fprintf(stdout, " Native VNC:      vnc://<printer-ip>:%u\n", vnc_port);
    if (enable_ws)  fprintf(stdout, " Web Browser VNC: http://<printer-ip>:%u\n", ws_port);
    fprintf(stdout, " Screen Geometry: %ux%u (%u bpp, target %u FPS)\n", fb.get_width(), fb.get_height(), fb.get_bpp(), target_fps);
    fprintf(stdout, " Input Control:   %s\n", injector.is_available() ? "Enabled (Virtual Touchscreen)" : "View-Only");
    fprintf(stdout, "-------------------------------------------------------\n");

    std::vector<Rect> dirty_rects;
    auto frame_duration = std::chrono::microseconds(1000000 / target_fps);

    while (g_running) {
        auto start_time = std::chrono::steady_clock::now();

        // Check network events
        if (enable_vnc) rfb.process_network(2);
        if (enable_ws)  ws.process_network(2);

        // Detect dirty regions and broadcast to connected clients
        if (rfb.get_client_count() > 0) {
            fb.detect_dirty_regions(dirty_rects);
            rfb.broadcast_updates(dirty_rects);
        }

        auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - start_time);
        if (elapsed < frame_duration) {
            std::this_thread::sleep_for(frame_duration - elapsed);
        }
    }

    fprintf(stdout, "\n[Main] Stopping OpenKE VNC Server...\n");
    if (enable_ws) ws.stop();
    if (enable_vnc) rfb.stop();
    injector.close_device();
    fb.close_device();
    fprintf(stdout, "[Main] Clean shutdown complete.\n");
    return 0;
}

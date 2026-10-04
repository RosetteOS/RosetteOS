#pragma once

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <memory>
#include <mutex>
#include "rfb_protocol.h"
#include "fb_device.h"
#include "uinput_injector.h"

enum HandshakeState {
    HS_WAIT_VERSION = 0,
    HS_WAIT_SECURITY_TYPE = 1,
    HS_WAIT_CLIENT_INIT = 2,
    HS_INITIALIZED = 3
};

struct RfbClient {
    int fd;
    bool is_websocket;
    HandshakeState handshake_state;
    int rfb_minor;
    bool initialized;
    bool has_pending_update;
    bool req_incremental;
    RfbPixelFormat format;
    std::vector<int32_t> encodings;
    std::vector<uint8_t> in_buffer;

    RfbClient(int sock_fd, bool ws = false)
        : fd(sock_fd)
        , is_websocket(ws)
        , handshake_state(HS_WAIT_VERSION)
        , rfb_minor(8)
        , initialized(false)
        , has_pending_update(false)
        , req_incremental(false)
    {
        std::memset(&format, 0, sizeof(format));
    }
};

class RfbServer {
public:
    RfbServer(FBDevice& fb, UinputInjector& injector, uint16_t port = 5900, const std::string& desktop_name = "OpenKE Display");
    ~RfbServer();

    bool start();
    void stop();

    // Process network I/O for standard TCP clients
    void process_network(int timeout_ms = 10);

    // Broadcast dirty frame rectangles to connected clients
    void broadcast_updates(const std::vector<Rect>& dirty_rects);

    // WebSocket client hooks
    void register_ws_client(int client_fd);
    void handle_ws_data(int client_fd, const uint8_t* data, size_t len);
    void unregister_ws_client(int client_fd);

    uint16_t get_port() const { return m_port; }
    size_t get_client_count();

private:
    FBDevice& m_fb;
    UinputInjector& m_injector;
    uint16_t m_port;
    std::string m_desktop_name;
    int m_listen_fd;
    bool m_running;

    std::mutex m_clients_mutex;
    std::vector<std::shared_ptr<RfbClient>> m_clients;

    bool handle_handshake(std::shared_ptr<RfbClient>& client);
    bool handle_client_messages(std::shared_ptr<RfbClient>& client);
    void send_server_init(std::shared_ptr<RfbClient>& client);
    void send_framebuffer_update(std::shared_ptr<RfbClient>& client, const std::vector<Rect>& rects);
    bool send_data(std::shared_ptr<RfbClient>& client, const void* data, size_t len);
    void remove_client(int fd);
};

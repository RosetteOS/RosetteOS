#pragma once

#include <cstdint>
#include <string>
#include <vector>
#include <memory>
#include <mutex>

class RfbServer;

class WebSocketServer {
public:
    WebSocketServer(RfbServer& rfb, uint16_t port = 5800);
    ~WebSocketServer();

    bool start();
    void stop();

    void process_network(int timeout_ms = 10);
    bool send_binary(int client_fd, const void* data, size_t len);

private:
    RfbServer& m_rfb;
    uint16_t m_port;
    int m_listen_fd;
    bool m_running;

    struct WsClientState {
        int fd;
        bool is_ws_handshake_done;
        std::vector<uint8_t> in_buffer;

        WsClientState(int sfd) : fd(sfd), is_ws_handshake_done(false) {}
    };

    std::mutex m_clients_mutex;
    std::vector<std::shared_ptr<WsClientState>> m_clients;

    bool handle_http_request(std::shared_ptr<WsClientState>& client);
    bool handle_ws_frames(std::shared_ptr<WsClientState>& client);
    void send_http_response(int fd, int status_code, const std::string& content_type, const std::string& body);
    void remove_client(int fd);
};

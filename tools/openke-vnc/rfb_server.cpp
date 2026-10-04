#include "rfb_server.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <cstring>
#include <cstdio>
#include <algorithm>

// WebSocket binary frame wrapper declaration
extern bool ws_send_binary_frame(int client_fd, const void* data, size_t len);

RfbServer::RfbServer(FBDevice& fb, UinputInjector& injector, uint16_t port, const std::string& desktop_name)
    : m_fb(fb)
    , m_injector(injector)
    , m_port(port)
    , m_desktop_name(desktop_name)
    , m_listen_fd(-1)
    , m_running(false)
{
}

RfbServer::~RfbServer() {
    stop();
}

bool RfbServer::start() {
    stop();

    m_listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (m_listen_fd < 0) {
        fprintf(stderr, "[RfbServer] Error: Failed to create socket.\n");
        return false;
    }

    int opt = 1;
    setsockopt(m_listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    // Non-blocking mode
    int flags = fcntl(m_listen_fd, F_GETFL, 0);
    fcntl(m_listen_fd, F_SETFL, flags | O_NONBLOCK);

    sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(m_port);

    if (bind(m_listen_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[RfbServer] Error: Failed to bind to port %u.\n", m_port);
        close(m_listen_fd);
        m_listen_fd = -1;
        return false;
    }

    if (listen(m_listen_fd, 8) < 0) {
        fprintf(stderr, "[RfbServer] Error: listen() failed.\n");
        close(m_listen_fd);
        m_listen_fd = -1;
        return false;
    }

    m_running = true;
    fprintf(stdout, "[RfbServer] Listening for standard VNC clients on port %u\n", m_port);
    return true;
}

void RfbServer::stop() {
    m_running = false;
    if (m_listen_fd >= 0) {
        close(m_listen_fd);
        m_listen_fd = -1;
    }

    std::lock_guard<std::mutex> lock(m_clients_mutex);
    for (auto& client : m_clients) {
        if (!client->is_websocket && client->fd >= 0) {
            close(client->fd);
        }
    }
    m_clients.clear();
}

size_t RfbServer::get_client_count() {
    std::lock_guard<std::mutex> lock(m_clients_mutex);
    return m_clients.size();
}

void RfbServer::register_ws_client(int client_fd) {
    std::lock_guard<std::mutex> lock(m_clients_mutex);
    auto client = std::make_shared<RfbClient>(client_fd, true);
    client->format = m_fb.get_native_format();
    m_clients.push_back(client);
    fprintf(stdout, "[RfbServer] Registered WebSocket VNC client (fd %d)\n", client_fd);

    // Send RFB version greeting
    const char* greeting = RFB_VERSION_STRING;
    send_data(client, greeting, std::strlen(greeting));
}

void RfbServer::unregister_ws_client(int client_fd) {
    std::lock_guard<std::mutex> lock(m_clients_mutex);
    m_clients.erase(
        std::remove_if(m_clients.begin(), m_clients.end(), [client_fd](const std::shared_ptr<RfbClient>& c) {
            return c->fd == client_fd;
        }),
        m_clients.end()
    );
    fprintf(stdout, "[RfbServer] Unregistered WebSocket VNC client (fd %d)\n", client_fd);
}

void RfbServer::handle_ws_data(int client_fd, const uint8_t* data, size_t len) {
    std::shared_ptr<RfbClient> client = nullptr;
    {
        std::lock_guard<std::mutex> lock(m_clients_mutex);
        for (auto& c : m_clients) {
            if (c->fd == client_fd) {
                client = c;
                break;
            }
        }
    }

    if (!client) return;

    size_t old_sz = client->in_buffer.size();
    client->in_buffer.resize(old_sz + len);
    std::memcpy(client->in_buffer.data() + old_sz, data, len);

    if (!client->initialized) {
        handle_handshake(client);
    } else {
        handle_client_messages(client);
    }
}

void RfbServer::process_network(int timeout_ms) {
    if (!m_running || m_listen_fd < 0) return;

    std::vector<pollfd> pfds;
    std::vector<std::shared_ptr<RfbClient>> active_clients;

    {
        std::lock_guard<std::mutex> lock(m_clients_mutex);
        // Listen socket
        pollfd l_pfd;
        l_pfd.fd = m_listen_fd;
        l_pfd.events = POLLIN;
        l_pfd.revents = 0;
        pfds.push_back(l_pfd);

        for (auto& c : m_clients) {
            if (!c->is_websocket) {
                pollfd c_pfd;
                c_pfd.fd = c->fd;
                c_pfd.events = POLLIN;
                c_pfd.revents = 0;
                pfds.push_back(c_pfd);
                active_clients.push_back(c);
            }
        }
    }

    int ret = poll(pfds.data(), pfds.size(), timeout_ms);
    if (ret <= 0) return;

    // Check new TCP connection
    if (pfds[0].revents & POLLIN) {
        sockaddr_in client_addr;
        socklen_t addr_len = sizeof(client_addr);
        int client_fd = accept(m_listen_fd, (struct sockaddr*)&client_addr, &addr_len);
        if (client_fd >= 0) {
            int flags = fcntl(client_fd, F_GETFL, 0);
            fcntl(client_fd, F_SETFL, flags | O_NONBLOCK);

            int nodelay = 1;
            setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));

            auto client = std::make_shared<RfbClient>(client_fd, false);
            client->format = m_fb.get_native_format();

            {
                std::lock_guard<std::mutex> lock(m_clients_mutex);
                m_clients.push_back(client);
            }

            fprintf(stdout, "[RfbServer] Accepted native VNC client connection (fd %d)\n", client_fd);

            // Send RFB version greeting
            const char* greeting = RFB_VERSION_STRING;
            send_data(client, greeting, std::strlen(greeting));
        }
    }

    // Process client data
    for (size_t i = 1; i < pfds.size(); ++i) {
        auto& pfd = pfds[i];
        auto& client = active_clients[i - 1];

        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
            remove_client(client->fd);
            continue;
        }

        if (pfd.revents & POLLIN) {
            uint8_t buf[4096];
            ssize_t n = recv(client->fd, buf, sizeof(buf), 0);
            if (n <= 0) {
                remove_client(client->fd);
                continue;
            }

            size_t old_sz = client->in_buffer.size();
            client->in_buffer.resize(old_sz + n);
            std::memcpy(client->in_buffer.data() + old_sz, buf, n);

            if (!client->initialized) {
                if (!handle_handshake(client)) {
                    remove_client(client->fd);
                }
            } else {
                if (!handle_client_messages(client)) {
                    remove_client(client->fd);
                }
            }
        }
    }
}

bool RfbServer::handle_handshake(std::shared_ptr<RfbClient>& client) {
    auto& buf = client->in_buffer;

    // Step 1: Wait for client version string "RFB 003.00x\n" (12 bytes)
    if (client->handshake_state == HS_WAIT_VERSION) {
        if (buf.size() < 12) return true; // Wait for full header

        if (std::memcmp(buf.data(), "RFB ", 4) != 0) {
            fprintf(stderr, "[RfbServer] Invalid RFB client header.\n");
            return false;
        }

        int major = 3, minor = 8;
        char ver_str[13];
        std::memcpy(ver_str, buf.data(), 12);
        ver_str[12] = '\0';
        std::sscanf(ver_str, "RFB %03d.%03d", &major, &minor);
        client->rfb_minor = minor;

        buf.erase(buf.begin(), buf.begin() + 12);

        if (minor >= 7) {
            // Send Security Types: 1 type supported -> None (1)
            uint8_t sec_types[2] = { 1, RFB_SEC_NONE };
            send_data(client, sec_types, 2);
            client->handshake_state = HS_WAIT_SECURITY_TYPE;
        } else {
            // RFB 3.3: Send 4-byte security type directly (1 = None)
            uint32_t sec_none = htobe32(RFB_SEC_NONE);
            send_data(client, &sec_none, 4);
            client->handshake_state = HS_WAIT_CLIENT_INIT;
        }
        return true;
    }

    // Step 2: Client selects security type (1 byte)
    if (client->handshake_state == HS_WAIT_SECURITY_TYPE) {
        if (buf.empty()) return true;

        uint8_t chosen_sec = buf[0];
        buf.erase(buf.begin());

        if (chosen_sec != RFB_SEC_NONE) {
            fprintf(stderr, "[RfbServer] Client requested unsupported security type: %u\n", chosen_sec);
            uint32_t fail = htobe32(RFB_SEC_RESULT_FAIL);
            send_data(client, &fail, 4);
            return false;
        }

        if (client->rfb_minor >= 8) {
            // Send SecurityResult: 0 (OK)
            uint32_t ok = htobe32(RFB_SEC_RESULT_OK);
            send_data(client, &ok, 4);
        }

        client->handshake_state = HS_WAIT_CLIENT_INIT;
    }

    // Step 3: Wait for ClientInit (1 byte shared flag)
    if (client->handshake_state == HS_WAIT_CLIENT_INIT) {
        if (buf.empty()) return true;

        uint8_t shared_flag = buf[0];
        buf.erase(buf.begin());
        (void)shared_flag;

        // Send ServerInit
        send_server_init(client);
        client->handshake_state = HS_INITIALIZED;
        client->initialized = true;
        client->has_pending_update = true;
        client->req_incremental = false;
        return true;
    }

    return true;
}

void RfbServer::send_server_init(std::shared_ptr<RfbClient>& client) {
    RfbServerInit init;
    init.fb_width = htobe16(m_fb.get_width());
    init.fb_height = htobe16(m_fb.get_height());
    init.format = m_fb.get_native_format();
    init.name_length = htobe32(m_desktop_name.size());

    std::vector<uint8_t> packet(sizeof(init) + m_desktop_name.size());
    std::memcpy(packet.data(), &init, sizeof(init));
    std::memcpy(packet.data() + sizeof(init), m_desktop_name.data(), m_desktop_name.size());

    send_data(client, packet.data(), packet.size());
    fprintf(stdout, "[RfbServer] Sent ServerInit: %ux%u to client (fd %d)\n", m_fb.get_width(), m_fb.get_height(), client->fd);
}

bool RfbServer::handle_client_messages(std::shared_ptr<RfbClient>& client) {
    auto& buf = client->in_buffer;

    while (!buf.empty()) {
        uint8_t msg_type = buf[0];

        switch (msg_type) {
            case RFB_MSG_SET_PIXEL_FORMAT: {
                if (buf.size() < sizeof(RfbSetPixelFormat)) return true;
                const auto* msg = reinterpret_cast<const RfbSetPixelFormat*>(buf.data());
                client->format = msg->format;
                buf.erase(buf.begin(), buf.begin() + sizeof(RfbSetPixelFormat));
                break;
            }

            case RFB_MSG_SET_ENCODINGS: {
                if (buf.size() < 4) return true;
                uint16_t count = be16toh(*reinterpret_cast<const uint16_t*>(buf.data() + 2));
                size_t needed = 4 + count * 4;
                if (buf.size() < needed) return true;

                client->encodings.clear();
                for (size_t i = 0; i < count; ++i) {
                    int32_t enc = static_cast<int32_t>(be32toh(*reinterpret_cast<const uint32_t*>(buf.data() + 4 + i * 4)));
                    client->encodings.push_back(enc);
                }
                buf.erase(buf.begin(), buf.begin() + needed);
                break;
            }

            case RFB_MSG_FB_UPDATE_REQ: {
                if (buf.size() < sizeof(RfbFramebufferUpdateRequest)) return true;
                const auto* msg = reinterpret_cast<const RfbFramebufferUpdateRequest*>(buf.data());
                client->has_pending_update = true;
                client->req_incremental = (msg->incremental != 0);
                buf.erase(buf.begin(), buf.begin() + sizeof(RfbFramebufferUpdateRequest));
                break;
            }

            case RFB_MSG_KEY_EVENT: {
                if (buf.size() < sizeof(RfbKeyEvent)) return true;
                const auto* msg = reinterpret_cast<const RfbKeyEvent*>(buf.data());
                uint32_t key = be32toh(msg->key);
                bool down = (msg->down_flag != 0);
                m_injector.inject_key(key, down);
                buf.erase(buf.begin(), buf.begin() + sizeof(RfbKeyEvent));
                break;
            }

            case RFB_MSG_POINTER_EVENT: {
                if (buf.size() < sizeof(RfbPointerEvent)) return true;
                const auto* msg = reinterpret_cast<const RfbPointerEvent*>(buf.data());
                uint16_t x = be16toh(msg->x);
                uint16_t y = be16toh(msg->y);
                m_injector.inject_pointer(x, y, msg->button_mask);
                buf.erase(buf.begin(), buf.begin() + sizeof(RfbPointerEvent));
                break;
            }

            case RFB_MSG_CLIENT_CUT_TEXT: {
                if (buf.size() < 8) return true;
                uint32_t len = be32toh(*reinterpret_cast<const uint32_t*>(buf.data() + 4));
                size_t needed = 8 + len;
                if (buf.size() < needed) return true;
                buf.erase(buf.begin(), buf.begin() + needed);
                break;
            }

            default: {
                fprintf(stderr, "[RfbServer] Unknown message type %u. Disconnecting client %d.\n", msg_type, client->fd);
                return false;
            }
        }
    }
    return true;
}

void RfbServer::broadcast_updates(const std::vector<Rect>& dirty_rects) {
    if (dirty_rects.empty()) return;

    std::vector<std::shared_ptr<RfbClient>> clients_copy;
    {
        std::lock_guard<std::mutex> lock(m_clients_mutex);
        clients_copy = m_clients;
    }

    for (auto& client : clients_copy) {
        if (!client->initialized || !client->has_pending_update) continue;

        if (!client->req_incremental) {
            // Full screen update requested
            Rect full_rect = { 0, 0, m_fb.get_width(), m_fb.get_height() };
            std::vector<Rect> full_vec = { full_rect };
            send_framebuffer_update(client, full_vec);
        } else {
            send_framebuffer_update(client, dirty_rects);
        }
        client->has_pending_update = false;
    }
}

void RfbServer::send_framebuffer_update(std::shared_ptr<RfbClient>& client, const std::vector<Rect>& rects) {
    if (rects.empty()) return;

    // Header: type (0), pad (0), number of rects (uint16_t)
    uint16_t rect_count = static_cast<uint16_t>(rects.size());
    std::vector<uint8_t> update_buf;
    update_buf.reserve(4 + rects.size() * 1024);

    update_buf.push_back(RFB_MSG_FB_UPDATE);
    update_buf.push_back(0); // padding
    update_buf.push_back(static_cast<uint8_t>((rect_count >> 8) & 0xFF));
    update_buf.push_back(static_cast<uint8_t>(rect_count & 0xFF));

    std::vector<uint8_t> pixel_data;
    for (const auto& r : rects) {
        uint8_t hdr_bytes[12];
        hdr_bytes[0] = static_cast<uint8_t>((r.x >> 8) & 0xFF);
        hdr_bytes[1] = static_cast<uint8_t>(r.x & 0xFF);
        hdr_bytes[2] = static_cast<uint8_t>((r.y >> 8) & 0xFF);
        hdr_bytes[3] = static_cast<uint8_t>(r.y & 0xFF);
        hdr_bytes[4] = static_cast<uint8_t>((r.w >> 8) & 0xFF);
        hdr_bytes[5] = static_cast<uint8_t>(r.w & 0xFF);
        hdr_bytes[6] = static_cast<uint8_t>((r.h >> 8) & 0xFF);
        hdr_bytes[7] = static_cast<uint8_t>(r.h & 0xFF);
        hdr_bytes[8] = 0; // Raw encoding is 0
        hdr_bytes[9] = 0;
        hdr_bytes[10] = 0;
        hdr_bytes[11] = 0;
        update_buf.insert(update_buf.end(), hdr_bytes, hdr_bytes + 12);

        m_fb.extract_rect(r, client->format, pixel_data);
        update_buf.insert(update_buf.end(), pixel_data.begin(), pixel_data.end());
    }

    send_data(client, update_buf.data(), update_buf.size());
}

bool RfbServer::send_data(std::shared_ptr<RfbClient>& client, const void* data, size_t len) {
    if (client->is_websocket) {
        return ws_send_binary_frame(client->fd, data, len);
    } else {
        const uint8_t* ptr = static_cast<const uint8_t*>(data);
        size_t sent = 0;
        while (sent < len) {
            ssize_t n = send(client->fd, ptr + sent, len - sent, MSG_NOSIGNAL);
            if (n <= 0) {
                remove_client(client->fd);
                return false;
            }
            sent += n;
        }
        return true;
    }
}

void RfbServer::remove_client(int fd) {
    std::lock_guard<std::mutex> lock(m_clients_mutex);
    m_clients.erase(
        std::remove_if(m_clients.begin(), m_clients.end(), [fd](const std::shared_ptr<RfbClient>& c) {
            if (c->fd == fd) {
                if (!c->is_websocket && c->fd >= 0) close(c->fd);
                return true;
            }
            return false;
        }),
        m_clients.end()
    );
    fprintf(stdout, "[RfbServer] Client disconnected (fd %d)\n", fd);
}

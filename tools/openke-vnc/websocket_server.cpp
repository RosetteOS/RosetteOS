#include "websocket_server.h"
#include "rfb_server.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <cstring>
#include <cstdio>
#include <sstream>
#include <algorithm>

static WebSocketServer* g_ws_instance = nullptr;

bool ws_send_binary_frame(int client_fd, const void* data, size_t len) {
    if (g_ws_instance) {
        return g_ws_instance->send_binary(client_fd, data, len);
    }
    return false;
}

// ---------------------------------------------------------
// Standalone SHA-1 (RFC 3174) & Base64
// ---------------------------------------------------------
namespace crypto {
    struct SHA1Context {
        uint32_t state[5];
        uint32_t count[2];
        uint8_t  buffer[64];
    };

    static void SHA1Transform(uint32_t state[5], const uint8_t buffer[64]) {
        uint32_t a = state[0], b = state[1], c = state[2], d = state[3], e = state[4];
        uint32_t block[80];

        for (int i = 0; i < 16; ++i) {
            block[i] = (buffer[i * 4] << 24) | (buffer[i * 4 + 1] << 16) |
                       (buffer[i * 4 + 2] << 8) | (buffer[i * 4 + 3]);
        }
        for (int i = 16; i < 80; ++i) {
            uint32_t val = block[i - 3] ^ block[i - 8] ^ block[i - 14] ^ block[i - 16];
            block[i] = (val << 1) | (val >> 31);
        }

        for (int i = 0; i < 80; ++i) {
            uint32_t f, k;
            if (i < 20) {
                f = (b & c) | ((~b) & d);
                k = 0x5A827999;
            } else if (i < 40) {
                f = b ^ c ^ d;
                k = 0x6ED9EBA1;
            } else if (i < 60) {
                f = (b & c) | (b & d) | (c & d);
                k = 0x8F1BBCDC;
            } else {
                f = b ^ c ^ d;
                k = 0xCA62C1D6;
            }
            uint32_t temp = ((a << 5) | (a >> 27)) + f + e + k + block[i];
            e = d;
            d = c;
            c = (b << 30) | (b >> 2);
            b = a;
            a = temp;
        }

        state[0] += a;
        state[1] += b;
        state[2] += c;
        state[3] += d;
        state[4] += e;
    }

    static void SHA1Init(SHA1Context* context) {
        context->state[0] = 0x67452301;
        context->state[1] = 0xEFCDAB89;
        context->state[2] = 0x98BADCFE;
        context->state[3] = 0x10325476;
        context->state[4] = 0xC3D2E1F0;
        context->count[0] = context->count[1] = 0;
    }

    static void SHA1Update(SHA1Context* context, const uint8_t* data, size_t len) {
        size_t i, j;
        j = (context->count[0] >> 3) & 63;
        if ((context->count[0] += static_cast<uint32_t>(len << 3)) < (len << 3)) context->count[1]++;
        context->count[1] += static_cast<uint32_t>(len >> 29);
        if ((j + len) > 63) {
            std::memcpy(&context->buffer[j], data, (i = 64 - j));
            SHA1Transform(context->state, context->buffer);
            for (; i + 63 < len; i += 64) {
                SHA1Transform(context->state, &data[i]);
            }
            j = 0;
        } else {
            i = 0;
        }
        std::memcpy(&context->buffer[j], &data[i], len - i);
    }

    static void SHA1Final(uint8_t digest[20], SHA1Context* context) {
        uint8_t finalcount[8];
        for (int i = 0; i < 8; ++i) {
            finalcount[i] = static_cast<uint8_t>((context->count[(i >= 4 ? 0 : 1)] >> ((3 - (i & 3)) * 8)) & 255);
        }
        uint8_t c = 0200;
        SHA1Update(context, &c, 1);
        while ((context->count[0] & 504) != 448) {
            c = 0;
            SHA1Update(context, &c, 1);
        }
        SHA1Update(context, finalcount, 8);
        for (int i = 0; i < 20; ++i) {
            digest[i] = static_cast<uint8_t>((context->state[i >> 2] >> ((3 - (i & 3)) * 8)) & 255);
        }
    }

    static std::string Base64Encode(const uint8_t* data, size_t len) {
        static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        std::string out;
        out.reserve(((len + 2) / 3) * 4);
        size_t i = 0;
        while (i < len) {
            uint32_t oct_a = i < len ? data[i++] : 0;
            uint32_t oct_b = i < len ? data[i++] : 0;
            uint32_t oct_c = i < len ? data[i++] : 0;
            uint32_t triple = (oct_a << 16) | (oct_b << 8) | oct_c;

            out.push_back(tbl[(triple >> 18) & 0x3F]);
            out.push_back(tbl[(triple >> 12) & 0x3F]);
            out.push_back(i > len + 1 ? '=' : tbl[(triple >> 6) & 0x3F]);
            out.push_back(i > len ? '=' : tbl[triple & 0x3F]);
        }
        return out;
    }
}

// ---------------------------------------------------------
// Embedded HTML5 Web VNC Client (Modern, Responsive, Zero Deps)
// ---------------------------------------------------------
static const char* EMBEDDED_WEB_HTML = R"rawhtml(<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
    <title>OpenKE Remote Display</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            background: #121214;
            color: #e0e0e0;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            overflow: hidden;
            touch-action: none;
        }
        #header {
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            height: 48px;
            background: #1a1a1e;
            border-bottom: 1px solid #2a2a30;
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 0 16px;
            z-index: 10;
        }
        #title {
            font-size: 15px;
            font-weight: 600;
            color: #4fc3f7;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        #status-badge {
            font-size: 12px;
            padding: 4px 10px;
            border-radius: 12px;
            background: #2a2a30;
            color: #aaa;
            font-weight: 500;
        }
        #status-badge.connected { background: #1b5e20; color: #a5d6a7; }
        #status-badge.disconnected { background: #b71c1c; color: #ef9a9a; }
        #screen-container {
            margin-top: 48px;
            display: flex;
            align-items: center;
            justify-content: center;
            width: 100vw;
            height: calc(100vh - 48px);
            background: #000;
        }
        canvas {
            image-rendering: pixelated;
            image-rendering: crisp-edges;
            box-shadow: 0 8px 32px rgba(0,0,0,0.8);
            max-width: 100%;
            max-height: 100%;
            cursor: pointer;
        }
        #toolbar {
            position: fixed;
            bottom: 16px;
            display: flex;
            gap: 10px;
            background: rgba(26,26,30,0.85);
            backdrop-filter: blur(8px);
            padding: 6px 12px;
            border-radius: 20px;
            border: 1px solid #333;
        }
        .btn {
            background: #2a2a32;
            color: #eee;
            border: 1px solid #444;
            padding: 6px 12px;
            border-radius: 14px;
            font-size: 13px;
            cursor: pointer;
            transition: 0.15s;
        }
        .btn:hover { background: #3a3a44; }
    </style>
</head>
<body>
    <div id="header">
        <div id="title">
            <span>📺</span>
            <span>OpenKE Remote Display</span>
        </div>
        <div id="status-badge">Connecting...</div>
    </div>
    <div id="screen-container">
        <canvas id="screen" width="480" height="272"></canvas>
    </div>
    <div id="toolbar">
        <button class="btn" onclick="requestFullScreen()">⛶ Fullscreen</button>
        <button class="btn" onclick="reconnect()">🔄 Reconnect</button>
    </div>

    <script>
        const canvas = document.getElementById('screen');
        const ctx = canvas.getContext('2d');
        const badge = document.getElementById('status-badge');
        let ws = null;
        let fbWidth = 480, fbHeight = 272;
        let bpp = 16;
        let handshaked = false;
        let isDown = false;

        function setStatus(text, stateClass) {
            badge.textContent = text;
            badge.className = stateClass || '';
        }

        function connect() {
            setStatus('Connecting...', '');
            const loc = window.location;
            const wsProto = (loc.protocol === 'https:') ? 'wss:' : 'ws:';
            const wsUrl = wsProto + '//' + loc.host + '/ws';

            ws = new WebSocket(wsUrl, ['binary']);
            ws.binaryType = 'arraybuffer';

            ws.onopen = () => {
                setStatus('Handshaking...', '');
                handshaked = false;
            };

            ws.onclose = () => {
                setStatus('Disconnected', 'disconnected');
                setTimeout(connect, 2000);
            };

            ws.onerror = (e) => {
                setStatus('Error', 'disconnected');
            };

            let handshakeStep = 0;

            ws.onmessage = (evt) => {
                const data = new Uint8Array(evt.data);
                const view = new DataView(evt.data);

                if (handshakeStep === 0) {
                    // Expecting RFB version "RFB 003.008\n"
                    const enc = new TextDecoder().decode(data);
                    if (enc.startsWith('RFB ')) {
                        ws.send(new TextEncoder().encode('RFB 003.008\n'));
                        handshakeStep = 1;
                    }
                    return;
                }

                if (handshakeStep === 1) {
                    // Security types
                    const numSec = data[0];
                    // Pick None (1)
                    ws.send(new Uint8Array([1]));
                    handshakeStep = 2;
                    return;
                }

                if (handshakeStep === 2) {
                    // SecurityResult: 0 OK (4 bytes)
                    const res = view.getUint32(0, false);
                    if (res === 0) {
                        // Send ClientInit (shared = 1)
                        ws.send(new Uint8Array([1]));
                        handshakeStep = 3;
                    }
                    return;
                }

                if (handshakeStep === 3) {
                    // ServerInit
                    fbWidth = view.getUint16(0, false);
                    fbHeight = view.getUint16(2, false);
                    bpp = data[4];
                    canvas.width = fbWidth;
                    canvas.height = fbHeight;
                    handshakeStep = 4;
                    handshaked = true;
                    setStatus('Live (' + fbWidth + 'x' + fbHeight + ')', 'connected');

                    // Request initial full frame update
                    sendFbUpdateRequest(0, 0, 0, fbWidth, fbHeight);
                    return;
                }

                if (handshaked) {
                    // Process RFB Server Message
                    const msgType = data[0];
                    if (msgType === 0) { // FramebufferUpdate
                        const numRects = view.getUint16(2, false);
                        let offset = 4;

                        for (let r = 0; r < numRects && offset < data.length; ++r) {
                            const rx = view.getUint16(offset, false);
                            const ry = view.getUint16(offset + 2, false);
                            const rw = view.getUint16(offset + 4, false);
                            const rh = view.getUint16(offset + 6, false);
                            const enc = view.getInt32(offset + 8, false);
                            offset += 12;

                            if (enc === 0) { // Raw
                                const imgData = ctx.createImageData(rw, rh);
                                const d32 = new Uint32Array(imgData.data.buffer);

                                if (bpp === 16) {
                                    const rectPixels = rw * rh;
                                    for (let i = 0; i < rectPixels; ++i) {
                                        const p16 = view.getUint16(offset + i * 2, true); // Little endian RGB565
                                        const r5 = (p16 >> 11) & 0x1F;
                                        const g6 = (p16 >> 5) & 0x3F;
                                        const b5 = p16 & 0x1F;
                                        const r8 = (r5 * 255 / 31) | 0;
                                        const g8 = (g6 * 255 / 63) | 0;
                                        const b8 = (b5 * 255 / 31) | 0;
                                        d32[i] = (255 << 24) | (b8 << 16) | (g8 << 8) | r8;
                                    }
                                    offset += rectPixels * 2;
                                } else if (bpp === 32) {
                                    const rectPixels = rw * rh;
                                    for (let i = 0; i < rectPixels; ++i) {
                                        const p32 = view.getUint32(offset + i * 4, true);
                                        const r8 = (p32 >> 16) & 0xFF;
                                        const g8 = (p32 >> 8) & 0xFF;
                                        const b8 = p32 & 0xFF;
                                        d32[i] = (255 << 24) | (b8 << 16) | (g8 << 8) | r8;
                                    }
                                    offset += rectPixels * 4;
                                }
                                ctx.putImageData(imgData, rx, ry);
                            }
                        }

                        // Schedule next incremental update request
                        setTimeout(() => {
                            if (handshaked && ws && ws.readyState === WebSocket.OPEN) {
                                sendFbUpdateRequest(1, 0, 0, fbWidth, fbHeight);
                            }
                        }, 30);
                    }
                }
            };
        }

        function sendFbUpdateRequest(incremental, x, y, w, h) {
            const buf = new ArrayBuffer(10);
            const view = new DataView(buf);
            view.setUint8(0, 3); // FramebufferUpdateRequest
            view.setUint8(1, incremental ? 1 : 0);
            view.setUint16(2, x, false);
            view.setUint16(4, y, false);
            view.setUint16(6, w, false);
            view.setUint16(8, h, false);
            ws.send(buf);
        }

        function sendPointerEvent(buttonMask, x, y) {
            if (!handshaked || !ws || ws.readyState !== WebSocket.OPEN) return;
            const buf = new ArrayBuffer(6);
            const view = new DataView(buf);
            view.setUint8(0, 5); // PointerEvent
            view.setUint8(1, buttonMask);
            view.setUint16(2, Math.max(0, Math.min(fbWidth, x)), false);
            view.setUint16(4, Math.max(0, Math.min(fbHeight, y)), false);
            ws.send(buf);
        }

        function getCanvasCoords(evt) {
            const rect = canvas.getBoundingClientRect();
            const clientX = evt.touches ? evt.touches[0].clientX : evt.clientX;
            const clientY = evt.touches ? evt.touches[0].clientY : evt.clientY;
            const scaleX = canvas.width / rect.width;
            const scaleY = canvas.height / rect.height;
            return {
                x: Math.round((clientX - rect.left) * scaleX),
                y: Math.round((clientY - rect.top) * scaleY)
            };
        }

        // Pointer / Touch interaction handlers
        canvas.addEventListener('mousedown', (e) => {
            isDown = true;
            const p = getCanvasCoords(e);
            sendPointerEvent(1, p.x, p.y);
        });

        window.addEventListener('mousemove', (e) => {
            if (isDown) {
                const p = getCanvasCoords(e);
                sendPointerEvent(1, p.x, p.y);
            }
        });

        window.addEventListener('mouseup', (e) => {
            if (isDown) {
                isDown = false;
                const p = getCanvasCoords(e);
                sendPointerEvent(0, p.x, p.y);
            }
        });

        canvas.addEventListener('touchstart', (e) => {
            e.preventDefault();
            isDown = true;
            const p = getCanvasCoords(e);
            sendPointerEvent(1, p.x, p.y);
        }, { passive: false });

        canvas.addEventListener('touchmove', (e) => {
            e.preventDefault();
            if (isDown) {
                const p = getCanvasCoords(e);
                sendPointerEvent(1, p.x, p.y);
            }
        }, { passive: false });

        canvas.addEventListener('touchend', (e) => {
            e.preventDefault();
            if (isDown) {
                isDown = false;
                const p = getCanvasCoords(e);
                sendPointerEvent(0, p.x, p.y);
            }
        }, { passive: false });

        function requestFullScreen() {
            if (!document.fullscreenElement) {
                document.documentElement.requestFullscreen().catch(err => {});
            } else {
                document.exitFullscreen();
            }
        }

        function reconnect() {
            if (ws) ws.close();
            connect();
        }

        connect();
    </script>
</body>
</html>
)rawhtml";

WebSocketServer::WebSocketServer(RfbServer& rfb, uint16_t port)
    : m_rfb(rfb)
    , m_port(port)
    , m_listen_fd(-1)
    , m_running(false)
{
    g_ws_instance = this;
}

WebSocketServer::~WebSocketServer() {
    stop();
    if (g_ws_instance == this) {
        g_ws_instance = nullptr;
    }
}

bool WebSocketServer::start() {
    stop();

    m_listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (m_listen_fd < 0) {
        fprintf(stderr, "[WebSocketServer] Error: Failed to create socket.\n");
        return false;
    }

    int opt = 1;
    setsockopt(m_listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    int flags = fcntl(m_listen_fd, F_GETFL, 0);
    fcntl(m_listen_fd, F_SETFL, flags | O_NONBLOCK);

    sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(m_port);

    if (bind(m_listen_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[WebSocketServer] Error: Failed to bind to port %u.\n", m_port);
        close(m_listen_fd);
        m_listen_fd = -1;
        return false;
    }

    if (listen(m_listen_fd, 8) < 0) {
        fprintf(stderr, "[WebSocketServer] Error: listen() failed.\n");
        close(m_listen_fd);
        m_listen_fd = -1;
        return false;
    }

    m_running = true;
    fprintf(stdout, "[WebSocketServer] Web VNC Client listening on http://0.0.0.0:%u\n", m_port);
    return true;
}

void WebSocketServer::stop() {
    m_running = false;
    if (m_listen_fd >= 0) {
        close(m_listen_fd);
        m_listen_fd = -1;
    }

    std::lock_guard<std::mutex> lock(m_clients_mutex);
    for (auto& client : m_clients) {
        if (client->fd >= 0) close(client->fd);
    }
    m_clients.clear();
}

void WebSocketServer::process_network(int timeout_ms) {
    if (!m_running || m_listen_fd < 0) return;

    std::vector<pollfd> pfds;
    std::vector<std::shared_ptr<WsClientState>> active_clients;

    {
        std::lock_guard<std::mutex> lock(m_clients_mutex);
        pollfd l_pfd;
        l_pfd.fd = m_listen_fd;
        l_pfd.events = POLLIN;
        l_pfd.revents = 0;
        pfds.push_back(l_pfd);

        for (auto& c : m_clients) {
            pollfd c_pfd;
            c_pfd.fd = c->fd;
            c_pfd.events = POLLIN;
            c_pfd.revents = 0;
            pfds.push_back(c_pfd);
            active_clients.push_back(c);
        }
    }

    int ret = poll(pfds.data(), pfds.size(), timeout_ms);
    if (ret <= 0) return;

    // New connection
    if (pfds[0].revents & POLLIN) {
        sockaddr_in client_addr;
        socklen_t addr_len = sizeof(client_addr);
        int client_fd = accept(m_listen_fd, (struct sockaddr*)&client_addr, &addr_len);
        if (client_fd >= 0) {
            int flags = fcntl(client_fd, F_GETFL, 0);
            fcntl(client_fd, F_SETFL, flags | O_NONBLOCK);

            int nodelay = 1;
            setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));

            auto client = std::make_shared<WsClientState>(client_fd);
            {
                std::lock_guard<std::mutex> lock(m_clients_mutex);
                m_clients.push_back(client);
            }
        }
    }

    // Process clients
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

            if (!client->is_ws_handshake_done) {
                if (!handle_http_request(client)) {
                    remove_client(client->fd);
                }
            } else {
                if (!handle_ws_frames(client)) {
                    remove_client(client->fd);
                }
            }
        }
    }
}

bool WebSocketServer::handle_http_request(std::shared_ptr<WsClientState>& client) {
    std::string req(reinterpret_cast<const char*>(client->in_buffer.data()), client->in_buffer.size());
    size_t header_end = req.find("\r\n\r\n");
    if (header_end == std::string::npos) {
        return (client->in_buffer.size() < 8192); // Keep waiting if not too large
    }

    // Check if WebSocket Upgrade request
    size_t ws_pos = req.find("Upgrade: websocket");
    if (ws_pos == std::string::npos) {
        ws_pos = req.find("upgrade: websocket");
    }

    if (ws_pos != std::string::npos) {
        // Extract Sec-WebSocket-Key
        std::string key_hdr = "Sec-WebSocket-Key: ";
        size_t key_pos = req.find(key_hdr);
        if (key_pos == std::string::npos) {
            key_hdr = "sec-websocket-key: ";
            key_pos = req.find(key_hdr);
        }

        if (key_pos == std::string::npos) {
            send_http_response(client->fd, 400, "text/plain", "Missing Sec-WebSocket-Key");
            return false;
        }

        size_t val_start = key_pos + key_hdr.length();
        size_t val_end = req.find("\r\n", val_start);
        std::string sec_key = req.substr(val_start, val_end - val_start);

        // Compute accept key: SHA1(sec_key + GUID)
        std::string magic = sec_key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        crypto::SHA1Context ctx;
        crypto::SHA1Init(&ctx);
        crypto::SHA1Update(&ctx, reinterpret_cast<const uint8_t*>(magic.data()), magic.length());
        uint8_t digest[20];
        crypto::SHA1Final(digest, &ctx);
        std::string accept_val = crypto::Base64Encode(digest, 20);

        std::ostringstream oss;
        oss << "HTTP/1.1 101 Switching Protocols\r\n"
            << "Upgrade: websocket\r\n"
            << "Connection: Upgrade\r\n"
            << "Sec-WebSocket-Accept: " << accept_val << "\r\n"
            << "Sec-WebSocket-Protocol: binary\r\n\r\n";

        std::string resp = oss.str();
        send(client->fd, resp.data(), resp.length(), MSG_NOSIGNAL);

        client->in_buffer.erase(client->in_buffer.begin(), client->in_buffer.begin() + header_end + 4);
        client->is_ws_handshake_done = true;

        m_rfb.register_ws_client(client->fd);
        return true;
    }

    // Serve HTML5 Client
    send_http_response(client->fd, 200, "text/html; charset=UTF-8", EMBEDDED_WEB_HTML);
    return false; // Close HTTP request after serving page
}

bool WebSocketServer::handle_ws_frames(std::shared_ptr<WsClientState>& client) {
    auto& buf = client->in_buffer;

    while (buf.size() >= 2) {
        uint8_t b1 = buf[0];
        uint8_t b2 = buf[1];

        uint8_t opcode = b1 & 0x0F;
        bool is_masked = (b2 & 0x80) != 0;
        uint64_t payload_len = b2 & 0x7F;

        size_t header_len = 2;
        if (payload_len == 126) {
            if (buf.size() < 4) return true;
            payload_len = (buf[2] << 8) | buf[3];
            header_len = 4;
        } else if (payload_len == 127) {
            if (buf.size() < 10) return true;
            payload_len = 0;
            for (int i = 0; i < 8; ++i) {
                payload_len = (payload_len << 8) | buf[2 + i];
            }
            header_len = 10;
        }

        if (is_masked) header_len += 4;

        if (buf.size() < header_len + payload_len) {
            return true; // Wait for full frame
        }

        uint8_t mask[4] = { 0, 0, 0, 0 };
        if (is_masked) {
            size_t mask_offset = header_len - 4;
            std::memcpy(mask, buf.data() + mask_offset, 4);
        }

        uint8_t* payload_ptr = buf.data() + header_len;
        if (is_masked) {
            for (size_t i = 0; i < payload_len; ++i) {
                payload_ptr[i] ^= mask[i % 4];
            }
        }

        // Handle Opcode
        if (opcode == 0x08) { // Close
            return false;
        } else if (opcode == 0x09) { // Ping -> send Pong
            uint8_t pong[2] = { 0x8A, 0x00 };
            send(client->fd, pong, 2, MSG_NOSIGNAL);
        } else if (opcode == 0x01 || opcode == 0x02) { // Text or Binary RFB data
            m_rfb.handle_ws_data(client->fd, payload_ptr, payload_len);
        }

        buf.erase(buf.begin(), buf.begin() + header_len + payload_len);
    }
    return true;
}

bool WebSocketServer::send_binary(int client_fd, const void* data, size_t len) {
    const uint8_t* src = static_cast<const uint8_t*>(data);
    std::vector<uint8_t> frame;

    uint8_t b1 = 0x82; // FIN + Binary opcode
    frame.push_back(b1);

    if (len < 126) {
        frame.push_back(static_cast<uint8_t>(len));
    } else if (len <= 0xFFFF) {
        frame.push_back(126);
        frame.push_back(static_cast<uint8_t>((len >> 8) & 0xFF));
        frame.push_back(static_cast<uint8_t>(len & 0xFF));
    } else {
        frame.push_back(127);
        for (int i = 7; i >= 0; --i) {
            frame.push_back(static_cast<uint8_t>((len >> (i * 8)) & 0xFF));
        }
    }

    frame.insert(frame.end(), src, src + len);

    size_t sent = 0;
    while (sent < frame.size()) {
        ssize_t n = send(client_fd, frame.data() + sent, frame.size() - sent, MSG_NOSIGNAL);
        if (n <= 0) {
            remove_client(client_fd);
            return false;
        }
        sent += n;
    }
    return true;
}

void WebSocketServer::send_http_response(int fd, int status_code, const std::string& content_type, const std::string& body) {
    std::ostringstream oss;
    oss << "HTTP/1.1 " << status_code << " OK\r\n"
        << "Content-Type: " << content_type << "\r\n"
        << "Content-Length: " << body.length() << "\r\n"
        << "Connection: close\r\n\r\n"
        << body;
    std::string resp = oss.str();
    send(fd, resp.data(), resp.length(), MSG_NOSIGNAL);
    close(fd);
}

void WebSocketServer::remove_client(int fd) {
    m_rfb.unregister_ws_client(fd);

    std::lock_guard<std::mutex> lock(m_clients_mutex);
    m_clients.erase(
        std::remove_if(m_clients.begin(), m_clients.end(), [fd](const std::shared_ptr<WsClientState>& c) {
            if (c->fd == fd) {
                close(c->fd);
                return true;
            }
            return false;
        }),
        m_clients.end()
    );
}

#include "uinput_injector.h"
#include <fcntl.h>
#include <unistd.h>
#include <cstring>
#include <cstdio>
#include <sys/ioctl.h>
#include <linux/uinput.h>
#include "rfb_protocol.h"

UinputInjector::UinputInjector()
    : m_fd(-1)
    , m_width(480)
    , m_height(272)
    , m_btn_pressed(false)
    , m_last_x(0)
    , m_last_y(0)
{
}

UinputInjector::~UinputInjector() {
    close_device();
}

bool UinputInjector::init(uint16_t screen_w, uint16_t screen_h) {
    close_device();
    m_width = screen_w;
    m_height = screen_h;

    const char* paths[] = { "/dev/uinput", "/dev/input/uinput", nullptr };
    for (int i = 0; paths[i]; ++i) {
        m_fd = open(paths[i], O_WRONLY | O_NONBLOCK);
        if (m_fd >= 0) break;
    }

    if (m_fd < 0) {
        fprintf(stderr, "[UinputInjector] Notice: /dev/uinput not available. Input injection disabled (view-only mode).\n");
        return false;
    }

    // Enable touch/mouse absolute events
    ioctl(m_fd, UI_SET_EVBIT, EV_KEY);
    ioctl(m_fd, UI_SET_KEYBIT, BTN_TOUCH);
    ioctl(m_fd, UI_SET_KEYBIT, BTN_LEFT);
    ioctl(m_fd, UI_SET_KEYBIT, BTN_RIGHT);

    // Keyboard keys
    ioctl(m_fd, UI_SET_KEYBIT, KEY_ENTER);
    ioctl(m_fd, UI_SET_KEYBIT, KEY_ESC);
    ioctl(m_fd, UI_SET_KEYBIT, KEY_BACKSPACE);
    ioctl(m_fd, UI_SET_KEYBIT, KEY_TAB);
    ioctl(m_fd, UI_SET_KEYBIT, KEY_SPACE);
    ioctl(m_fd, UI_SET_KEYBIT, KEY_UP);
    ioctl(m_fd, UI_SET_KEYBIT, KEY_DOWN);
    ioctl(m_fd, UI_SET_KEYBIT, KEY_LEFT);
    ioctl(m_fd, UI_SET_KEYBIT, KEY_RIGHT);
    ioctl(m_fd, UI_SET_KEYBIT, KEY_HOME);
    ioctl(m_fd, UI_SET_KEYBIT, KEY_END);
    ioctl(m_fd, UI_SET_KEYBIT, KEY_PAGEUP);
    ioctl(m_fd, UI_SET_KEYBIT, KEY_PAGEDOWN);

    ioctl(m_fd, UI_SET_EVBIT, EV_ABS);
    ioctl(m_fd, UI_SET_ABSBIT, ABS_X);
    ioctl(m_fd, UI_SET_ABSBIT, ABS_Y);
    ioctl(m_fd, UI_SET_ABSBIT, ABS_PRESSURE);

    struct uinput_user_dev uidev;
    std::memset(&uidev, 0, sizeof(uidev));
    std::snprintf(uidev.name, UINPUT_MAX_NAME_SIZE, "OpenKE VNC Remote Input");
    uidev.id.bustype = BUS_VIRTUAL;
    uidev.id.vendor  = 0x1234;
    uidev.id.product = 0x5678;
    uidev.id.version = 1;

    uidev.absmin[ABS_X] = 0;
    uidev.absmax[ABS_X] = m_width;
    uidev.absmin[ABS_Y] = 0;
    uidev.absmax[ABS_Y] = m_height;
    uidev.absmin[ABS_PRESSURE] = 0;
    uidev.absmax[ABS_PRESSURE] = 255;

    if (write(m_fd, &uidev, sizeof(uidev)) < 0) {
        fprintf(stderr, "[UinputInjector] Error: Failed to write uinput_user_dev.\n");
        close_device();
        return false;
    }

    if (ioctl(m_fd, UI_DEV_CREATE) < 0) {
        fprintf(stderr, "[UinputInjector] Error: UI_DEV_CREATE failed.\n");
        close_device();
        return false;
    }

    fprintf(stdout, "[UinputInjector] Created virtual touch device 'OpenKE VNC Remote Input' (%ux%u)\n", m_width, m_height);
    return true;
}

void UinputInjector::close_device() {
    if (m_fd >= 0) {
        ioctl(m_fd, UI_DEV_DESTROY);
        close(m_fd);
        m_fd = -1;
    }
}

void UinputInjector::emit_event(uint16_t type, uint16_t code, int32_t val) {
    if (m_fd < 0) return;
    struct input_event ev;
    std::memset(&ev, 0, sizeof(ev));
    ev.type = type;
    ev.code = code;
    ev.value = val;
    ssize_t res = write(m_fd, &ev, sizeof(ev));
    (void)res;
}

void UinputInjector::sync() {
    emit_event(EV_SYN, SYN_REPORT, 0);
}

void UinputInjector::inject_pointer(uint16_t x, uint16_t y, uint8_t button_mask) {
    if (m_fd < 0) return;

    bool pressed = (button_mask & 0x01) != 0; // Left click / touch

    if (pressed) {
        emit_event(EV_ABS, ABS_X, x);
        emit_event(EV_ABS, ABS_Y, y);
        emit_event(EV_ABS, ABS_PRESSURE, 200);
        if (!m_btn_pressed) {
            emit_event(EV_KEY, BTN_TOUCH, 1);
            emit_event(EV_KEY, BTN_LEFT, 1);
            m_btn_pressed = true;
        }
        sync();
    } else {
        if (m_btn_pressed) {
            emit_event(EV_ABS, ABS_PRESSURE, 0);
            emit_event(EV_KEY, BTN_TOUCH, 0);
            emit_event(EV_KEY, BTN_LEFT, 0);
            sync();
            m_btn_pressed = false;
        }
    }
    m_last_x = x;
    m_last_y = y;
}

uint16_t UinputInjector::keysym_to_keycode(uint32_t keysym) {
    switch (keysym) {
        case XK_Return:    return KEY_ENTER;
        case XK_Escape:    return KEY_ESC;
        case XK_BackSpace: return KEY_BACKSPACE;
        case XK_Tab:       return KEY_TAB;
        case XK_Space:     return KEY_SPACE;
        case XK_Up:        return KEY_UP;
        case XK_Down:      return KEY_DOWN;
        case XK_Left:      return KEY_LEFT;
        case XK_Right:     return KEY_RIGHT;
        case XK_Home:      return KEY_HOME;
        case XK_End:       return KEY_END;
        case XK_Page_Up:   return KEY_PAGEUP;
        case XK_Page_Down: return KEY_PAGEDOWN;
        default:           return 0;
    }
}

void UinputInjector::inject_key(uint32_t keysym, bool down) {
    if (m_fd < 0) return;
    uint16_t code = keysym_to_keycode(keysym);
    if (code != 0) {
        emit_event(EV_KEY, code, down ? 1 : 0);
        sync();
    }
}

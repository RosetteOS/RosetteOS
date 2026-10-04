#pragma once

#include <cstdint>
#include <endian.h>

// RFB Protocol Version 3.8
#define RFB_VERSION_STRING "RFB 003.008\n"

// Security Types
enum RfbSecurityType : uint8_t {
    RFB_SEC_INVALID = 0,
    RFB_SEC_NONE    = 1,
    RFB_SEC_VNC_AUTH = 2,
};

// Security Result
#define RFB_SEC_RESULT_OK   0
#define RFB_SEC_RESULT_FAIL 1

// Client to Server Message Types
enum RfbClientMsgType : uint8_t {
    RFB_MSG_SET_PIXEL_FORMAT = 0,
    RFB_MSG_SET_ENCODINGS    = 2,
    RFB_MSG_FB_UPDATE_REQ    = 3,
    RFB_MSG_KEY_EVENT        = 4,
    RFB_MSG_POINTER_EVENT    = 5,
    RFB_MSG_CLIENT_CUT_TEXT  = 6,
};

// Server to Client Message Types
enum RfbServerMsgType : uint8_t {
    RFB_MSG_FB_UPDATE        = 0,
    RFB_MSG_SET_COLOUR_MAP   = 1,
    RFB_MSG_BELL             = 2,
    RFB_MSG_SERVER_CUT_TEXT  = 3,
};

// Encoding Types
enum RfbEncoding : int32_t {
    RFB_ENCODING_RAW       = 0,
    RFB_ENCODING_COPYRECT  = 1,
    RFB_ENCODING_RRE       = 2,
    RFB_ENCODING_CORRE     = 4,
    RFB_ENCODING_HEXTILE   = 5,
    RFB_ENCODING_ZRLE      = 16,
    RFB_ENCODING_DESKTOP_SIZE = -223,
};

#pragma pack(push, 1)

struct RfbPixelFormat {
    uint8_t  bits_per_pixel;
    uint8_t  depth;
    uint8_t  big_endian_flag;
    uint8_t  true_colour_flag;
    uint16_t red_max;
    uint16_t green_max;
    uint16_t blue_max;
    uint8_t  red_shift;
    uint8_t  green_shift;
    uint8_t  blue_shift;
    uint8_t  pad[3];
};

struct RfbServerInit {
    uint16_t fb_width;
    uint16_t fb_height;
    RfbPixelFormat format;
    uint32_t name_length;
};

struct RfbFramebufferUpdateRequest {
    uint8_t  type;
    uint8_t  incremental;
    uint16_t x;
    uint16_t y;
    uint16_t width;
    uint16_t height;
};

struct RfbSetPixelFormat {
    uint8_t  type;
    uint8_t  pad[3];
    RfbPixelFormat format;
};

struct RfbKeyEvent {
    uint8_t  type;
    uint8_t  down_flag;
    uint8_t  pad[2];
    uint32_t key;
};

struct RfbPointerEvent {
    uint8_t  type;
    uint8_t  button_mask;
    uint16_t x;
    uint16_t y;
};

struct RfbRectangleHeader {
    uint16_t x;
    uint16_t y;
    uint16_t width;
    uint16_t height;
    int32_t  encoding_type;
};

#pragma pack(pop)

// Common X11 Keysyms for RFB KeyEvent mapping
#define XK_BackSpace 0xff08
#define XK_Tab       0xff09
#define XK_Return    0xff0d
#define XK_Escape    0xff1b
#define XK_Delete    0xffff
#define XK_Home      0xff50
#define XK_Left      0xff51
#define XK_Up        0xff52
#define XK_Right     0xff53
#define XK_Down      0xff54
#define XK_Page_Up   0xff55
#define XK_Page_Down 0xff56
#define XK_End       0xff57
#define XK_Space     0x0020

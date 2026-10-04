#pragma once

#include <cstdint>
#include <string>
#include <vector>
#include <linux/fb.h>
#include "rfb_protocol.h"

struct Rect {
    uint16_t x;
    uint16_t y;
    uint16_t w;
    uint16_t h;
};

class FBDevice {
public:
    FBDevice();
    ~FBDevice();

    bool open_device(const std::string& dev_path = "/dev/fb0");
    void close_device();

    uint16_t get_width() const { return m_width; }
    uint16_t get_height() const { return m_height; }
    uint32_t get_stride() const { return m_stride; }
    uint8_t  get_bpp() const { return m_bpp; }
    RfbPixelFormat get_native_format() const { return m_native_format; }

    // Computes dirty rectangles comparing current mmapped fb against previous snapshot.
    // Returns true if there were any changes.
    bool detect_dirty_regions(std::vector<Rect>& dirty_rects, bool force_full = false);

    // Extracts pixel data for a rectangle, converting from fb format to requested format if necessary.
    void extract_rect(const Rect& rect, const RfbPixelFormat& target_format, std::vector<uint8_t>& out_data);

private:
    int m_fd;
    uint8_t* m_fb_mem;
    size_t m_fb_size;
    uint16_t m_width;
    uint16_t m_height;
    uint32_t m_stride;
    uint8_t  m_bpp;
    fb_var_screeninfo m_vinfo;
    fb_fix_screeninfo m_finfo;
    RfbPixelFormat m_native_format;

    // Double buffer snapshot for dirty detection
    std::vector<uint8_t> m_prev_frame;
    uint32_t m_tile_cols;
    uint32_t m_tile_rows;
    std::vector<uint8_t> m_dirty_tiles;

    void update_native_format();
};

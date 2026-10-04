#include "fb_device.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <cstring>
#include <cstdio>
#include <algorithm>

#define TILE_SIZE 32

FBDevice::FBDevice()
    : m_fd(-1)
    , m_fb_mem(nullptr)
    , m_fb_size(0)
    , m_width(480)
    , m_height(272)
    , m_stride(480 * 2)
    , m_bpp(16)
    , m_tile_cols(0)
    , m_tile_rows(0)
{
    std::memset(&m_vinfo, 0, sizeof(m_vinfo));
    std::memset(&m_finfo, 0, sizeof(m_finfo));
    std::memset(&m_native_format, 0, sizeof(m_native_format));
}

FBDevice::~FBDevice() {
    close_device();
}

bool FBDevice::open_device(const std::string& dev_path) {
    close_device();

    m_fd = open(dev_path.c_str(), O_RDWR);
    if (m_fd < 0) {
        m_fd = open(dev_path.c_str(), O_RDONLY);
    }

    if (m_fd < 0) {
        fprintf(stderr, "[FBDevice] Warning: Failed to open %s. Using virtual 480x272 RGB565 fallback.\n", dev_path.c_str());
        m_width = 480;
        m_height = 272;
        m_bpp = 16;
        m_stride = m_width * 2;
        m_fb_size = m_stride * m_height;
        m_fb_mem = (uint8_t*)malloc(m_fb_size);
        if (m_fb_mem) {
            std::memset(m_fb_mem, 0x18, m_fb_size); // dark gray test background
        }
    } else {
        if (ioctl(m_fd, FBIOGET_VSCREENINFO, &m_vinfo) < 0) {
            fprintf(stderr, "[FBDevice] Error: FBIOGET_VSCREENINFO failed.\n");
            close_device();
            return false;
        }

        if (ioctl(m_fd, FBIOGET_FSCREENINFO, &m_finfo) < 0) {
            fprintf(stderr, "[FBDevice] Error: FBIOGET_FSCREENINFO failed.\n");
            close_device();
            return false;
        }

        m_width = m_vinfo.xres;
        m_height = m_vinfo.yres;
        m_bpp = m_vinfo.bits_per_pixel;
        m_stride = m_finfo.line_length ? m_finfo.line_length : (m_width * (m_bpp / 8));
        
        size_t map_len = (size_t)m_stride * (m_vinfo.yres_virtual ? m_vinfo.yres_virtual : m_height);
        if (m_finfo.smem_len > 0 && (size_t)m_finfo.smem_len > map_len) {
            map_len = m_finfo.smem_len;
        }
        m_fb_size = map_len;

        m_fb_mem = (uint8_t*)mmap(nullptr, m_fb_size, PROT_READ | PROT_WRITE, MAP_SHARED, m_fd, 0);
        if (m_fb_mem == MAP_FAILED) {
            m_fb_mem = (uint8_t*)mmap(nullptr, m_fb_size, PROT_READ, MAP_SHARED, m_fd, 0);
        }
        if (m_fb_mem == MAP_FAILED) {
            fprintf(stderr, "[FBDevice] Error: mmap failed on %s: %s\n", dev_path.c_str(), strerror(errno));
            m_fb_mem = nullptr;
            close_device();
            return false;
        }
    }

    update_native_format();

    m_tile_cols = (m_width + TILE_SIZE - 1) / TILE_SIZE;
    m_tile_rows = (m_height + TILE_SIZE - 1) / TILE_SIZE;
    m_dirty_tiles.assign(m_tile_cols * m_tile_rows, 1);

    size_t frame_bytes = m_stride * m_height;
    m_prev_frame.assign(frame_bytes, 0);

    fprintf(stdout, "[FBDevice] Opened %s: %ux%u @ %u bpp (stride %u bytes, %u tiles)\n",
            dev_path.c_str(), m_width, m_height, m_bpp, m_stride, m_tile_cols * m_tile_rows);
    return true;
}

void FBDevice::close_device() {
    if (m_fb_mem) {
        if (m_fd >= 0) {
            munmap(m_fb_mem, m_fb_size);
        } else {
            free(m_fb_mem);
        }
        m_fb_mem = nullptr;
    }
    if (m_fd >= 0) {
        close(m_fd);
        m_fd = -1;
    }
}

void FBDevice::update_native_format() {
    std::memset(&m_native_format, 0, sizeof(m_native_format));
    m_native_format.bits_per_pixel = m_bpp;
    m_native_format.big_endian_flag = 0;
    m_native_format.true_colour_flag = 1;

    if (m_bpp == 16) {
        m_native_format.depth = 16;
        m_native_format.red_max   = htobe16(31);
        m_native_format.green_max = htobe16(63);
        m_native_format.blue_max  = htobe16(31);
        if (m_vinfo.red.length > 0) {
            m_native_format.red_shift   = m_vinfo.red.offset;
            m_native_format.green_shift = m_vinfo.green.offset;
            m_native_format.blue_shift  = m_vinfo.blue.offset;
        } else {
            m_native_format.red_shift   = 11;
            m_native_format.green_shift = 5;
            m_native_format.blue_shift  = 0;
        }
    } else {
        m_native_format.depth = 24;
        m_native_format.bits_per_pixel = 32;
        m_native_format.red_max   = htobe16(255);
        m_native_format.green_max = htobe16(255);
        m_native_format.blue_max  = htobe16(255);
        if (m_vinfo.red.length > 0) {
            m_native_format.red_shift   = m_vinfo.red.offset;
            m_native_format.green_shift = m_vinfo.green.offset;
            m_native_format.blue_shift  = m_vinfo.blue.offset;
        } else {
            m_native_format.red_shift   = 16;
            m_native_format.green_shift = 8;
            m_native_format.blue_shift  = 0;
        }
    }
}

bool FBDevice::detect_dirty_regions(std::vector<Rect>& dirty_rects, bool force_full) {
    dirty_rects.clear();
    if (!m_fb_mem) return false;

    uint32_t y_offset = 0;
    if (m_fd >= 0 && ioctl(m_fd, FBIOGET_VSCREENINFO, &m_vinfo) == 0) {
        y_offset = m_vinfo.yoffset;
    }
    const uint8_t* active_fb = m_fb_mem + (y_offset * m_stride);

    if (force_full) {
        Rect full_rect = { 0, 0, m_width, m_height };
        dirty_rects.push_back(full_rect);
        // Copy entire frame to prev_frame
        std::memcpy(m_prev_frame.data(), active_fb, m_stride * m_height);
        return true;
    }

    uint32_t bytes_per_pixel = m_bpp / 8;
    bool has_changes = false;

    for (uint32_t ty = 0; ty < m_tile_rows; ++ty) {
        uint16_t y_start = ty * TILE_SIZE;
        uint16_t y_end = std::min<uint16_t>(y_start + TILE_SIZE, m_height);

        for (uint32_t tx = 0; tx < m_tile_cols; ++tx) {
            uint16_t x_start = tx * TILE_SIZE;
            uint16_t x_end = std::min<uint16_t>(x_start + TILE_SIZE, m_width);
            uint16_t tile_w = x_end - x_start;
            size_t row_bytes = tile_w * bytes_per_pixel;

            bool tile_changed = false;
            for (uint16_t y = y_start; y < y_end; ++y) {
                size_t offset = y * m_stride + (x_start * bytes_per_pixel);
                if (std::memcmp(active_fb + offset, m_prev_frame.data() + offset, row_bytes) != 0) {
                    tile_changed = true;
                    // Update previous frame snapshot for this line
                    std::memcpy(m_prev_frame.data() + offset, active_fb + offset, row_bytes);
                }
            }

            m_dirty_tiles[ty * m_tile_cols + tx] = tile_changed ? 1 : 0;
            if (tile_changed) {
                has_changes = true;
            }
        }
    }

    if (!has_changes) return false;

    // Merge adjacent dirty tiles horizontally per row to reduce rectangle count
    for (uint32_t ty = 0; ty < m_tile_rows; ++ty) {
        uint16_t y_start = ty * TILE_SIZE;
        uint16_t y_end = std::min<uint16_t>(y_start + TILE_SIZE, m_height);
        uint16_t tile_h = y_end - y_start;

        uint32_t tx = 0;
        while (tx < m_tile_cols) {
            if (!m_dirty_tiles[ty * m_tile_cols + tx]) {
                ++tx;
                continue;
            }

            uint32_t start_tx = tx;
            while (tx < m_tile_cols && m_dirty_tiles[ty * m_tile_cols + tx]) {
                ++tx;
            }

            uint16_t x_start = start_tx * TILE_SIZE;
            uint16_t x_end = std::min<uint16_t>(tx * TILE_SIZE, m_width);

            Rect r = { x_start, y_start, static_cast<uint16_t>(x_end - x_start), tile_h };
            dirty_rects.push_back(r);
        }
    }

    return true;
}

void FBDevice::extract_rect(const Rect& rect, const RfbPixelFormat& target_format, std::vector<uint8_t>& out_data) {
    if (!m_fb_mem) return;

    uint32_t y_offset = 0;
    if (m_fd >= 0 && ioctl(m_fd, FBIOGET_VSCREENINFO, &m_vinfo) == 0) {
        y_offset = m_vinfo.yoffset;
    }
    const uint8_t* active_fb = m_fb_mem + (y_offset * m_stride);

    uint32_t src_bpp = m_bpp;
    uint32_t dst_bpp = target_format.bits_per_pixel;
    uint32_t src_bytes_per_pixel = src_bpp / 8;
    uint32_t dst_bytes_per_pixel = dst_bpp / 8;

    size_t total_dst_bytes = rect.w * rect.h * dst_bytes_per_pixel;
    out_data.resize(total_dst_bytes);

    bool direct_copy = (src_bpp == dst_bpp) &&
                       (m_native_format.red_shift == target_format.red_shift) &&
                       (m_native_format.green_shift == target_format.green_shift) &&
                       (m_native_format.blue_shift == target_format.blue_shift);

    if (direct_copy) {
        // Fast direct row copy
        size_t row_bytes = rect.w * src_bytes_per_pixel;
        for (uint16_t y = 0; y < rect.h; ++y) {
            const uint8_t* src_row = active_fb + ((rect.y + y) * m_stride) + (rect.x * src_bytes_per_pixel);
            uint8_t* dst_row = out_data.data() + (y * row_bytes);
            std::memcpy(dst_row, src_row, row_bytes);
        }
        return;
    }

    // Format conversion (e.g. RGB565 -> RGB8888 or custom shifts)
    uint8_t* dst_ptr = out_data.data();

    for (uint16_t y = 0; y < rect.h; ++y) {
        const uint8_t* src_row = active_fb + ((rect.y + y) * m_stride) + (rect.x * src_bytes_per_pixel);

        for (uint16_t x = 0; x < rect.w; ++x) {
            uint32_t r = 0, g = 0, b = 0;

            if (src_bpp == 16) {
                uint16_t pixel = *reinterpret_cast<const uint16_t*>(src_row + (x * 2));
                // Extract 5-6-5 channels
                r = (pixel >> m_native_format.red_shift) & be16toh(m_native_format.red_max);
                g = (pixel >> m_native_format.green_shift) & be16toh(m_native_format.green_max);
                b = (pixel >> m_native_format.blue_shift) & be16toh(m_native_format.blue_max);

                // Scale to 8-bit [0..255]
                r = (r * 255) / 31;
                g = (g * 255) / 63;
                b = (b * 255) / 31;
            } else if (src_bpp == 32) {
                uint32_t pixel = *reinterpret_cast<const uint32_t*>(src_row + (x * 4));
                r = (pixel >> m_native_format.red_shift) & be16toh(m_native_format.red_max);
                g = (pixel >> m_native_format.green_shift) & be16toh(m_native_format.green_max);
                b = (pixel >> m_native_format.blue_shift) & be16toh(m_native_format.blue_max);
            }

            if (dst_bpp == 32) {
                uint32_t dst_pixel = (r << target_format.red_shift) |
                                     (g << target_format.green_shift) |
                                     (b << target_format.blue_shift);
                *reinterpret_cast<uint32_t*>(dst_ptr) = dst_pixel;
                dst_ptr += 4;
            } else if (dst_bpp == 16) {
                uint16_t r5 = (r * 31) / 255;
                uint16_t g6 = (g * 63) / 255;
                uint16_t b5 = (b * 31) / 255;
                uint16_t dst_pixel = (r5 << target_format.red_shift) |
                                     (g6 << target_format.green_shift) |
                                     (b5 << target_format.blue_shift);
                *reinterpret_cast<uint16_t*>(dst_ptr) = dst_pixel;
                dst_ptr += 2;
            }
        }
    }
}

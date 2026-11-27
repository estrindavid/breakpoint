// Breakpoint's drawing layer on Windows: Direct3D 11 + DirectComposition + Direct2D + DirectWrite
// behind a small C API, so Swift never handles COM. First-party code; links only system DLLs.
//
// A surface is one window's content: a premultiplied-alpha composition swap chain in a
// DirectComposition visual (so transparent pixels show what is behind the window, or the system
// backdrop), drawn with Direct2D in device-independent pixels and presented on the GPU.
// Coordinates are DIPs (1/96 inch); the surface's `scale` maps them to the window's pixels.
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BPSurface BPSurface;
typedef struct BPTextLayout BPTextLayout;

typedef struct BPColor {
    float r, g, b, a;  // straight (not premultiplied) alpha, 0…1
} BPColor;

typedef struct BPRect {
    float x, y, width, height;
} BPRect;

typedef struct BPSize {
    float width, height;
} BPSize;

typedef enum BPTextAlign {
    BPTextAlignLeading = 0,
    BPTextAlignCenter = 1,
    BPTextAlignTrailing = 2,
} BPTextAlign;

typedef struct BPTextStyle {
    const uint16_t *family;  // UTF-16, NUL-terminated; NULL = the system UI font
    float size;              // DIPs
    int weight;              // 100…900
    int italic;
    int monospacedDigits;    // tabular figures (timers)
    BPTextAlign align;
    int wrap;                // 0: one line, cut with an ellipsis; 1: wrap words
    float lineSpacing;       // 0 = the font's own
} BPTextStyle;

// MARK: Lifetime

/// The shared devices (once per process). Returns 0 on success, else the HRESULT.
int32_t bp_graphics_start(void);
void bp_graphics_stop(void);
/// The devices were lost (driver update, GPU reset): every surface must be recreated.
int bp_graphics_device_lost(void);

/// A surface for `hwnd` (created with WS_EX_NOREDIRECTIONBITMAP), `width`×`height` pixels.
BPSurface *bp_surface_create(void *hwnd, int width, int height, float scale);
void bp_surface_resize(BPSurface *surface, int width, int height, float scale);
void bp_surface_destroy(BPSurface *surface);

/// Starts a frame (cleared to transparent). Returns 0 when drawing can go ahead.
int bp_surface_begin(BPSurface *surface);
/// Ends the frame and presents it. Returns 0, or the HRESULT (device lost: recreate).
int32_t bp_surface_end(BPSurface *surface);

// MARK: State

void bp_push_clip_rounded(BPSurface *surface, BPRect rect, float radius);
void bp_pop_clip(BPSurface *surface);
/// Everything until the matching pop is drawn at `opacity`.
void bp_push_opacity(BPSurface *surface, float opacity);
void bp_pop_opacity(BPSurface *surface);
/// Translate then scale about (ox, oy); the transforms nest.
void bp_push_transform(BPSurface *surface, float dx, float dy, float scale, float ox, float oy);
void bp_pop_transform(BPSurface *surface);

// MARK: Shapes

void bp_clear(BPSurface *surface, BPColor color);
void bp_fill_rect(BPSurface *surface, BPRect rect, BPColor color);
void bp_fill_rounded(BPSurface *surface, BPRect rect, float radius, BPColor color);
void bp_stroke_rounded(BPSurface *surface, BPRect rect, float radius, float width, BPColor color);
void bp_fill_ellipse(BPSurface *surface, float cx, float cy, float rx, float ry, BPColor color);
void bp_stroke_ellipse(BPSurface *surface, float cx, float cy, float rx, float ry, float width, BPColor color);
/// An arc of the circle (cx, cy, r) from `start` to `end` (fractions of a turn, 0 = 12 o'clock,
/// clockwise), with round caps.
void bp_stroke_arc(BPSurface *surface, float cx, float cy, float r, float start, float end, float width, BPColor color);
void bp_line(BPSurface *surface, float x1, float y1, float x2, float y2, float width, BPColor color, int roundCaps);
/// A vertical (angle 90) or any-angle linear gradient across a rounded rect.
void bp_fill_rounded_gradient(BPSurface *surface, BPRect rect, float radius, BPColor from, BPColor to, float angleDegrees);
/// A soft radial light: `color` at the centre fading to transparent at `radius`.
void bp_fill_radial(BPSurface *surface, float cx, float cy, float rx, float ry, BPColor color);
/// A drop shadow for a rounded rect: Gaussian blur of `blur` DIPs, offset by (dx, dy).
void bp_shadow_rounded(BPSurface *surface, BPRect rect, float radius, float blur, float dx, float dy, BPColor color);
/// A path in SVG-like commands over float pairs: 'M' x y, 'L' x y, 'C' x1 y1 x2 y2 x y, 'Z'.
/// Filled when `strokeWidth` is 0, else stroked with round joins and caps.
void bp_path(BPSurface *surface, const char *commands, const float *points, int pointCount, BPColor color, float strokeWidth);

// MARK: Text

/// A laid-out paragraph (cache it: layout is the costly part), `maxWidth` wide (0 = unbounded).
BPTextLayout *bp_text_layout(const uint16_t *text, int length, BPTextStyle style, float maxWidth);
void bp_text_layout_release(BPTextLayout *layout);
BPSize bp_text_layout_size(BPTextLayout *layout);
void bp_draw_text_layout(BPSurface *surface, BPTextLayout *layout, float x, float y, BPColor color);
/// The index (UTF-16) of the character at (x, y) in the layout, for hit testing links; -1 if none.
int bp_text_layout_hit(BPTextLayout *layout, float x, float y);

/// Erase mode: shapes drawn while it is on are taken out of what was drawn before (their alpha is
/// how much: draw them opaque to punch holes).
void bp_set_erase(BPSurface *surface, int on);

// MARK: Icons

/// Draws with `draw` into a 32-bit `size`×`size` bitmap and returns an HICON (the tray mark).
typedef void (*BPIconDrawer)(BPSurface *surface, void *context);
void *bp_make_icon(int size, BPIconDrawer draw, void *context);
/// Same, into a premultiplied BGRA buffer of `size`×`size`×4 bytes (snapshots, tests).
int bp_render_pixels(int width, int height, float scale, BPIconDrawer draw, void *context, uint8_t *pixels);
/// Writes `width`×`height` premultiplied BGRA pixels as a PNG at `path` (UTF-16; snapshots). 0 on success.
int bp_write_png(const uint16_t *path, int width, int height, const uint8_t *pixels);

#ifdef __cplusplus
}
#endif

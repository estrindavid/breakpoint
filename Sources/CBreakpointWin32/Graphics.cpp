// Direct3D 11 + DirectComposition + Direct2D + DirectWrite behind BreakpointGraphics.h.
// Everything runs on the UI thread; the devices are created once and shared by every surface.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <dcomp.h>
#include <d2d1_1.h>
#include <d2d1effects.h>
#include <dwrite.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cmath>
#include <cstring>
#include <vector>

#include "BreakpointGraphics.h"

using Microsoft::WRL::ComPtr;

namespace {

struct Devices {
    ComPtr<ID3D11Device> d3d;
    ComPtr<IDXGIDevice> dxgi;
    ComPtr<IDXGIFactory2> dxgiFactory;
    ComPtr<ID2D1Factory1> d2dFactory;
    ComPtr<ID2D1Device> d2d;
    ComPtr<IDCompositionDevice> dcomp;
    ComPtr<IDWriteFactory> dwrite;
    ComPtr<IWICImagingFactory> wic;
    bool lost = false;
};

// Process-lifetime on purpose: releasing Direct3D and DirectComposition from a static destructor
// while the process exits can deadlock on the loader lock (the app would never finish quitting).
Devices &g = *new Devices();

const float kPi = 3.14159265358979f;

D2D1_COLOR_F color(BPColor c) { return D2D1::ColorF(c.r, c.g, c.b, c.a); }
D2D1_RECT_F rectF(BPRect r) { return D2D1::RectF(r.x, r.y, r.x + r.width, r.y + r.height); }
D2D1_ROUNDED_RECT rounded(BPRect r, float radius) {
    float limit = std::fmin(r.width, r.height) / 2;
    float rr = std::fmax(0.0f, std::fmin(radius, limit));
    return D2D1::RoundedRect(rectF(r), rr, rr);
}

HRESULT createDevices() {
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
                                  D3D_FEATURE_LEVEL_10_0, D3D_FEATURE_LEVEL_9_3};
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, levels, ARRAYSIZE(levels),
                                   D3D11_SDK_VERSION, &g.d3d, nullptr, nullptr);
    if (FAILED(hr)) {
        // No usable GPU (a VM, a remote session): the software rasterizer.
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, levels, ARRAYSIZE(levels),
                               D3D11_SDK_VERSION, &g.d3d, nullptr, nullptr);
    }
    if (FAILED(hr)) return hr;
    if (FAILED(hr = g.d3d.As(&g.dxgi))) return hr;
    ComPtr<IDXGIAdapter> adapter;
    if (FAILED(hr = g.dxgi->GetAdapter(&adapter))) return hr;
    if (FAILED(hr = adapter->GetParent(IID_PPV_ARGS(&g.dxgiFactory)))) return hr;
    D2D1_FACTORY_OPTIONS options = {};
    if (FAILED(hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), &options,
                                      reinterpret_cast<void **>(g.d2dFactory.ReleaseAndGetAddressOf()))))
        return hr;
    if (FAILED(hr = g.d2dFactory->CreateDevice(g.dxgi.Get(), &g.d2d))) return hr;
    if (FAILED(hr = DCompositionCreateDevice(g.dxgi.Get(), IID_PPV_ARGS(&g.dcomp)))) return hr;
    if (!g.dwrite) {
        if (FAILED(hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                            reinterpret_cast<IUnknown **>(g.dwrite.ReleaseAndGetAddressOf()))))
            return hr;
    }
    if (!g.wic) {
        hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&g.wic));
        if (FAILED(hr)) g.wic.Reset();  // icons fall back to the device path; not fatal
    }
    g.lost = false;
    return S_OK;
}

}  // namespace

struct BPSurface {
    HWND hwnd = nullptr;
    ComPtr<IDXGISwapChain1> swapChain;
    ComPtr<ID2D1DeviceContext> dc;
    ComPtr<ID2D1Bitmap1> target;
    ComPtr<IDCompositionTarget> compositionTarget;
    ComPtr<IDCompositionVisual> visual;
    ComPtr<ID2D1SolidColorBrush> brush;
    // An offscreen surface (icons, snapshots) draws into a WIC bitmap instead.
    ComPtr<IWICBitmap> wicBitmap;
    ComPtr<ID2D1RenderTarget> wicTarget;
    float scale = 1;
    int width = 0, height = 0;
    // While erasing: the target to return to and the shapes recorded meanwhile.
    ComPtr<ID2D1Image> eraseTarget;
    ComPtr<ID2D1CommandList> eraseList;
    std::vector<D2D1_MATRIX_3X2_F> transforms;
    bool drawing = false;

    ID2D1SolidColorBrush *solid(BPColor c) {
        if (!brush) dc->CreateSolidColorBrush(color(c), &brush);
        else brush->SetColor(color(c));
        return brush.Get();
    }
};

struct BPTextLayout {
    ComPtr<IDWriteTextLayout> layout;
};

namespace {

HRESULT attachTarget(BPSurface *s) {
    ComPtr<IDXGISurface> backBuffer;
    HRESULT hr = s->swapChain->GetBuffer(0, IID_PPV_ARGS(&backBuffer));
    if (FAILED(hr)) return hr;
    D2D1_BITMAP_PROPERTIES1 properties = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f * s->scale,
        96.0f * s->scale);
    s->target.Reset();
    return s->dc->CreateBitmapFromDxgiSurface(backBuffer.Get(), &properties, &s->target);
}

D2D1_MATRIX_3X2_F currentTransform(BPSurface *s) {
    return s->transforms.empty() ? D2D1::Matrix3x2F::Identity() : s->transforms.back();
}

ComPtr<ID2D1Geometry> roundedGeometry(BPRect rect, float radius) {
    ComPtr<ID2D1RoundedRectangleGeometry> geometry;
    g.d2dFactory->CreateRoundedRectangleGeometry(rounded(rect, radius), &geometry);
    return geometry;
}

}  // namespace

extern "C" {

int32_t bp_graphics_start(void) {
    if (g.d2d && !g.lost) return 0;
    g.d3d.Reset();
    g.dxgi.Reset();
    g.dxgiFactory.Reset();
    g.d2d.Reset();
    g.d2dFactory.Reset();
    g.dcomp.Reset();
    return createDevices();
}

void bp_graphics_stop(void) { g = Devices(); }

int bp_graphics_device_lost(void) { return g.lost ? 1 : 0; }

BPSurface *bp_surface_create(void *hwnd, int width, int height, float scale) {
    if (!g.d2d && FAILED(bp_graphics_start())) return nullptr;
    auto *s = new BPSurface();
    s->hwnd = static_cast<HWND>(hwnd);
    s->scale = scale > 0 ? scale : 1;
    s->width = width < 1 ? 1 : width;
    s->height = height < 1 ? 1 : height;
    DXGI_SWAP_CHAIN_DESC1 desc = {};
    desc.Width = s->width;
    desc.Height = s->height;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    if (FAILED(g.dxgiFactory->CreateSwapChainForComposition(g.d3d.Get(), &desc, nullptr, &s->swapChain)) ||
        FAILED(g.d2d->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &s->dc)) || FAILED(attachTarget(s)) ||
        FAILED(g.dcomp->CreateTargetForHwnd(s->hwnd, TRUE, &s->compositionTarget)) ||
        FAILED(g.dcomp->CreateVisual(&s->visual))) {
        delete s;
        return nullptr;
    }
    s->dc->SetUnitMode(D2D1_UNIT_MODE_DIPS);
    s->dc->SetDpi(96.0f * s->scale, 96.0f * s->scale);
    s->dc->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);  // ClearType needs an opaque target
    s->visual->SetContent(s->swapChain.Get());
    s->compositionTarget->SetRoot(s->visual.Get());
    g.dcomp->Commit();
    return s;
}

void bp_surface_resize(BPSurface *s, int width, int height, float scale) {
    if (!s || !s->swapChain) return;
    width = width < 1 ? 1 : width;
    height = height < 1 ? 1 : height;
    s->scale = scale > 0 ? scale : 1;
    s->dc->SetDpi(96.0f * s->scale, 96.0f * s->scale);
    if (width == s->width && height == s->height) {
        attachTarget(s);
        return;
    }
    s->dc->SetTarget(nullptr);
    s->target.Reset();
    s->width = width;
    s->height = height;
    if (SUCCEEDED(s->swapChain->ResizeBuffers(2, width, height, DXGI_FORMAT_B8G8R8A8_UNORM, 0))) attachTarget(s);
}

void bp_surface_destroy(BPSurface *s) {
    if (!s) return;
    if (s->compositionTarget) {
        s->compositionTarget->SetRoot(nullptr);
        if (g.dcomp) g.dcomp->Commit();
    }
    delete s;
}

int bp_surface_begin(BPSurface *s) {
    if (!s || !s->dc || s->drawing) return -1;
    if (s->swapChain) {
        if (!s->target) return -1;
        s->dc->SetTarget(s->target.Get());
    }
    s->dc->BeginDraw();
    s->dc->SetTransform(D2D1::Matrix3x2F::Identity());
    s->dc->Clear(D2D1::ColorF(0, 0, 0, 0));
    s->transforms.clear();
    s->drawing = true;
    return 0;
}

int32_t bp_surface_end(BPSurface *s) {
    if (!s || !s->drawing) return -1;
    s->drawing = false;
    HRESULT hr = s->dc->EndDraw();
    if (hr == D2DERR_RECREATE_TARGET) g.lost = true;
    if (FAILED(hr) || !s->swapChain) return hr;
    // Flip model in a composition visual never tears; 0 = do not block the UI thread for vblank.
    hr = s->swapChain->Present(0, 0);
    if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET) g.lost = true;
    return hr;
}

void bp_push_clip_rounded(BPSurface *s, BPRect rect, float radius) {
    if (!s) return;
    auto geometry = roundedGeometry(rect, radius);
    // The mask is in the current user space: the world transform already applies to it, so the
    // mask transform stays identity (passing the world transform again moved clips drawn inside
    // a transform).
    D2D1_LAYER_PARAMETERS1 params = D2D1::LayerParameters1(D2D1::InfiniteRect(), geometry.Get(),
                                                           D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, D2D1::IdentityMatrix());
    s->dc->PushLayer(params, nullptr);
}

void bp_pop_clip(BPSurface *s) {
    if (s) s->dc->PopLayer();
}

void bp_push_opacity(BPSurface *s, float opacity) {
    if (!s) return;
    D2D1_LAYER_PARAMETERS1 params = D2D1::LayerParameters1();
    params.opacity = opacity;
    s->dc->PushLayer(params, nullptr);
}

void bp_pop_opacity(BPSurface *s) {
    if (s) s->dc->PopLayer();
}

void bp_push_transform(BPSurface *s, float dx, float dy, float scale, float ox, float oy) {
    if (!s) return;
    D2D1_MATRIX_3X2_F local = D2D1::Matrix3x2F::Scale(scale, scale, D2D1::Point2F(ox, oy)) *
                              D2D1::Matrix3x2F::Translation(dx, dy);
    D2D1_MATRIX_3X2_F combined = local * currentTransform(s);
    s->transforms.push_back(combined);
    s->dc->SetTransform(combined);
}

void bp_pop_transform(BPSurface *s) {
    if (!s || s->transforms.empty()) return;
    s->transforms.pop_back();
    s->dc->SetTransform(currentTransform(s));
}

void bp_clear(BPSurface *s, BPColor c) {
    if (s) s->dc->Clear(color(c));
}

void bp_fill_rect(BPSurface *s, BPRect rect, BPColor c) {
    if (s) s->dc->FillRectangle(rectF(rect), s->solid(c));
}

void bp_fill_rounded(BPSurface *s, BPRect rect, float radius, BPColor c) {
    if (s) s->dc->FillRoundedRectangle(rounded(rect, radius), s->solid(c));
}

void bp_stroke_rounded(BPSurface *s, BPRect rect, float radius, float width, BPColor c) {
    if (!s) return;
    // Inset by half the stroke so it stays inside the rect, like a SwiftUI strokeBorder.
    BPRect inner = {rect.x + width / 2, rect.y + width / 2, rect.width - width, rect.height - width};
    s->dc->DrawRoundedRectangle(rounded(inner, radius - width / 2), s->solid(c), width);
}

void bp_fill_ellipse(BPSurface *s, float cx, float cy, float rx, float ry, BPColor c) {
    if (s) s->dc->FillEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), rx, ry), s->solid(c));
}

void bp_stroke_ellipse(BPSurface *s, float cx, float cy, float rx, float ry, float width, BPColor c) {
    if (s) s->dc->DrawEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), rx, ry), s->solid(c), width);
}

void bp_stroke_arc(BPSurface *s, float cx, float cy, float r, float start, float end, float width, BPColor c) {
    if (!s || end <= start) return;
    float sweep = end - start;
    if (sweep >= 0.9999f) {
        s->dc->DrawEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), r, r), s->solid(c), width);
        return;
    }
    auto point = [&](float t) {
        float a = (t * 2 * kPi) - kPi / 2;
        return D2D1::Point2F(cx + r * std::cos(a), cy + r * std::sin(a));
    };
    ComPtr<ID2D1PathGeometry> path;
    ComPtr<ID2D1GeometrySink> sink;
    if (FAILED(g.d2dFactory->CreatePathGeometry(&path)) || FAILED(path->Open(&sink))) return;
    sink->BeginFigure(point(start), D2D1_FIGURE_BEGIN_HOLLOW);
    sink->AddArc(D2D1::ArcSegment(point(end), D2D1::SizeF(r, r), 0, D2D1_SWEEP_DIRECTION_CLOCKWISE,
                                  sweep > 0.5f ? D2D1_ARC_SIZE_LARGE : D2D1_ARC_SIZE_SMALL));
    sink->EndFigure(D2D1_FIGURE_END_OPEN);
    sink->Close();
    ComPtr<ID2D1StrokeStyle> style;
    g.d2dFactory->CreateStrokeStyle(D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND,
                                                                D2D1_CAP_STYLE_ROUND),
                                    nullptr, 0, &style);
    s->dc->DrawGeometry(path.Get(), s->solid(c), width, style.Get());
}

void bp_line(BPSurface *s, float x1, float y1, float x2, float y2, float width, BPColor c, int roundCaps) {
    if (!s) return;
    ComPtr<ID2D1StrokeStyle> style;
    if (roundCaps) {
        g.d2dFactory->CreateStrokeStyle(D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND),
                                        nullptr, 0, &style);
    }
    s->dc->DrawLine(D2D1::Point2F(x1, y1), D2D1::Point2F(x2, y2), s->solid(c), width, style.Get());
}

void bp_fill_rounded_gradient(BPSurface *s, BPRect rect, float radius, BPColor from, BPColor to, float angle) {
    if (!s) return;
    D2D1_GRADIENT_STOP stops[2] = {{0, color(from)}, {1, color(to)}};
    ComPtr<ID2D1GradientStopCollection> collection;
    if (FAILED(s->dc->CreateGradientStopCollection(stops, 2, &collection))) return;
    float a = angle * kPi / 180;
    float cx = rect.x + rect.width / 2, cy = rect.y + rect.height / 2;
    float hx = std::cos(a) * rect.width / 2, hy = std::sin(a) * rect.height / 2;
    ComPtr<ID2D1LinearGradientBrush> brush;
    if (FAILED(s->dc->CreateLinearGradientBrush(
            D2D1::LinearGradientBrushProperties(D2D1::Point2F(cx - hx, cy - hy), D2D1::Point2F(cx + hx, cy + hy)),
            collection.Get(), &brush)))
        return;
    s->dc->FillRoundedRectangle(rounded(rect, radius), brush.Get());
}

void bp_fill_radial(BPSurface *s, float cx, float cy, float rx, float ry, BPColor c) {
    if (!s || rx <= 0 || ry <= 0) return;
    BPColor clear = c;
    clear.a = 0;
    D2D1_GRADIENT_STOP stops[3] = {{0, color(c)}, {0.55f, D2D1::ColorF(c.r, c.g, c.b, c.a * 0.35f)}, {1, color(clear)}};
    ComPtr<ID2D1GradientStopCollection> collection;
    if (FAILED(s->dc->CreateGradientStopCollection(stops, 3, &collection))) return;
    ComPtr<ID2D1RadialGradientBrush> brush;
    if (FAILED(s->dc->CreateRadialGradientBrush(
            D2D1::RadialGradientBrushProperties(D2D1::Point2F(cx, cy), D2D1::Point2F(0, 0), rx, ry), collection.Get(),
            &brush)))
        return;
    s->dc->FillEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), rx, ry), brush.Get());
}

void bp_shadow_rounded(BPSurface *s, BPRect rect, float radius, float blur, float dx, float dy, BPColor c) {
    if (!s || c.a <= 0) return;
    // The shape into a command list, through the Shadow effect, drawn under the card.
    ComPtr<ID2D1Image> previous;
    s->dc->GetTarget(&previous);
    ComPtr<ID2D1CommandList> list;
    if (FAILED(s->dc->CreateCommandList(&list))) return;
    D2D1_MATRIX_3X2_F transform;
    s->dc->GetTransform(&transform);
    s->dc->SetTarget(list.Get());
    s->dc->SetTransform(D2D1::Matrix3x2F::Identity());
    BPColor opaque = c;
    opaque.a = 1;
    s->dc->FillRoundedRectangle(rounded(rect, radius), s->solid(opaque));
    s->dc->SetTarget(previous.Get());
    list->Close();
    ComPtr<ID2D1Effect> shadow;
    if (FAILED(s->dc->CreateEffect(CLSID_D2D1Shadow, &shadow))) {
        s->dc->SetTransform(transform);
        return;
    }
    shadow->SetInput(0, list.Get());
    shadow->SetValue(D2D1_SHADOW_PROP_BLUR_STANDARD_DEVIATION, blur / 2);
    shadow->SetValue(D2D1_SHADOW_PROP_COLOR, D2D1::Vector4F(c.r, c.g, c.b, c.a));
    s->dc->SetTransform(transform);
    D2D1_POINT_2F offset = D2D1::Point2F(dx, dy);
    s->dc->DrawImage(shadow.Get(), &offset);
}

void bp_path(BPSurface *s, const char *commands, const float *p, int count, BPColor c, float strokeWidth) {
    if (!s || !commands) return;
    ComPtr<ID2D1PathGeometry> path;
    ComPtr<ID2D1GeometrySink> sink;
    if (FAILED(g.d2dFactory->CreatePathGeometry(&path)) || FAILED(path->Open(&sink))) return;
    int i = 0;
    bool open = false;
    for (const char *k = commands; *k; ++k) {
        switch (*k) {
        case 'M':
            if (open) sink->EndFigure(D2D1_FIGURE_END_OPEN);
            if (i + 2 > count) break;
            sink->BeginFigure(D2D1::Point2F(p[i], p[i + 1]),
                              strokeWidth > 0 ? D2D1_FIGURE_BEGIN_HOLLOW : D2D1_FIGURE_BEGIN_FILLED);
            open = true;
            i += 2;
            break;
        case 'L':
            if (i + 2 > count || !open) break;
            sink->AddLine(D2D1::Point2F(p[i], p[i + 1]));
            i += 2;
            break;
        case 'C':
            if (i + 6 > count || !open) break;
            sink->AddBezier(D2D1::BezierSegment(D2D1::Point2F(p[i], p[i + 1]), D2D1::Point2F(p[i + 2], p[i + 3]),
                                                D2D1::Point2F(p[i + 4], p[i + 5])));
            i += 6;
            break;
        case 'Q':
            if (i + 4 > count || !open) break;
            sink->AddQuadraticBezier(D2D1::QuadraticBezierSegment(D2D1::Point2F(p[i], p[i + 1]), D2D1::Point2F(p[i + 2], p[i + 3])));
            i += 4;
            break;
        case 'Z':
            if (open) sink->EndFigure(D2D1_FIGURE_END_CLOSED);
            open = false;
            break;
        default:
            break;
        }
    }
    if (open) sink->EndFigure(D2D1_FIGURE_END_OPEN);
    sink->Close();
    if (strokeWidth > 0) {
        ComPtr<ID2D1StrokeStyle> style;
        g.d2dFactory->CreateStrokeStyle(D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND,
                                                                    D2D1_CAP_STYLE_ROUND, D2D1_LINE_JOIN_ROUND),
                                        nullptr, 0, &style);
        s->dc->DrawGeometry(path.Get(), s->solid(c), strokeWidth, style.Get());
    } else {
        s->dc->FillGeometry(path.Get(), s->solid(c));
    }
}

BPTextLayout *bp_text_layout(const uint16_t *text, int length, BPTextStyle style, float maxWidth) {
    if (!g.dwrite) {
        if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                       reinterpret_cast<IUnknown **>(g.dwrite.ReleaseAndGetAddressOf()))))
            return nullptr;
    }
    const wchar_t *family = style.family ? reinterpret_cast<const wchar_t *>(style.family)
                                         : (style.size >= 20 ? L"Segoe UI Variable Display" : L"Segoe UI Variable Text");
    ComPtr<IDWriteTextFormat> format;
    int weight = style.weight < 100 ? 400 : (style.weight > 900 ? 900 : style.weight);
    if (FAILED(g.dwrite->CreateTextFormat(family, nullptr, static_cast<DWRITE_FONT_WEIGHT>(weight),
                                          style.italic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL,
                                          DWRITE_FONT_STRETCH_NORMAL, style.size > 0 ? style.size : 13, L"",
                                          &format)))
        return nullptr;
    // Alignment needs a box: unbounded text (maxWidth 0) is always laid out from its origin.
    BPTextAlign align = maxWidth > 0 ? style.align : BPTextAlignLeading;
    format->SetTextAlignment(align == BPTextAlignCenter     ? DWRITE_TEXT_ALIGNMENT_CENTER
                             : align == BPTextAlignTrailing ? DWRITE_TEXT_ALIGNMENT_TRAILING
                                                                  : DWRITE_TEXT_ALIGNMENT_LEADING);
    format->SetWordWrapping(style.wrap ? DWRITE_WORD_WRAPPING_WRAP : DWRITE_WORD_WRAPPING_NO_WRAP);
    if (style.lineSpacing > 0) {
        format->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, style.lineSpacing, style.lineSpacing * 0.8f);
    }
    if (!style.wrap) {
        DWRITE_TRIMMING trimming = {DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        ComPtr<IDWriteInlineObject> ellipsis;
        if (SUCCEEDED(g.dwrite->CreateEllipsisTrimmingSign(format.Get(), &ellipsis))) {
            format->SetTrimming(&trimming, ellipsis.Get());
        }
    }
    auto *result = new BPTextLayout();
    float width = maxWidth > 0 ? maxWidth : 100000.0f;
    if (FAILED(g.dwrite->CreateTextLayout(reinterpret_cast<const wchar_t *>(text), length, format.Get(), width,
                                          100000.0f, &result->layout))) {
        delete result;
        return nullptr;
    }
    if (style.monospacedDigits) {
        ComPtr<IDWriteTypography> typography;
        if (SUCCEEDED(g.dwrite->CreateTypography(&typography))) {
            typography->AddFontFeature({DWRITE_FONT_FEATURE_TAG_TABULAR_FIGURES, 1});
            result->layout->SetTypography(typography.Get(), {0, static_cast<UINT32>(length)});
        }
    }
    return result;
}

void bp_text_layout_release(BPTextLayout *layout) { delete layout; }

BPSize bp_text_layout_size(BPTextLayout *layout) {
    BPSize size = {0, 0};
    if (!layout) return size;
    DWRITE_TEXT_METRICS metrics;
    if (SUCCEEDED(layout->layout->GetMetrics(&metrics))) {
        // Trailing spaces count, so runs of text set one after another keep their spaces.
        size.width = metrics.widthIncludingTrailingWhitespace;
        size.height = metrics.height;
    }
    return size;
}

void bp_draw_text_layout(BPSurface *s, BPTextLayout *layout, float x, float y, BPColor c) {
    if (!s || !layout) return;
    s->dc->DrawTextLayout(D2D1::Point2F(x, y), layout->layout.Get(), s->solid(c), D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
}

int bp_text_layout_hit(BPTextLayout *layout, float x, float y) {
    if (!layout) return -1;
    BOOL trailing = FALSE, inside = FALSE;
    DWRITE_HIT_TEST_METRICS metrics;
    if (FAILED(layout->layout->HitTestPoint(x, y, &trailing, &inside, &metrics)) || !inside) return -1;
    return static_cast<int>(metrics.textPosition);
}

namespace {

/// An offscreen surface over a WIC bitmap (premultiplied BGRA).
BPSurface *offscreen(int width, int height, float scale) {
    if (!g.d2dFactory && FAILED(bp_graphics_start())) return nullptr;
    if (!g.wic) return nullptr;
    auto *s = new BPSurface();
    s->width = width;
    s->height = height;
    s->scale = scale;
    if (FAILED(g.wic->CreateBitmap(width, height, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, &s->wicBitmap))) {
        delete s;
        return nullptr;
    }
    D2D1_RENDER_TARGET_PROPERTIES properties = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
        96.0f * scale, 96.0f * scale);
    if (FAILED(g.d2dFactory->CreateWicBitmapRenderTarget(s->wicBitmap.Get(), properties, &s->wicTarget)) ||
        FAILED(s->wicTarget.As(&s->dc))) {
        delete s;
        return nullptr;
    }
    s->dc->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    return s;
}

bool copyPixels(BPSurface *s, uint8_t *pixels) {
    WICRect rect = {0, 0, s->width, s->height};
    return SUCCEEDED(s->wicBitmap->CopyPixels(&rect, s->width * 4, s->width * s->height * 4, pixels));
}

}  // namespace

int bp_render_pixels(int width, int height, float scale, BPIconDrawer draw, void *context, uint8_t *pixels) {
    BPSurface *s = offscreen(width, height, scale);
    if (!s) return -1;
    bp_surface_begin(s);
    draw(s, context);
    bp_surface_end(s);
    bool ok = copyPixels(s, pixels);
    delete s;
    return ok ? 0 : -1;
}

void bp_set_erase(BPSurface *s, int on) {
    if (!s) return;
    if (on) {
        // Record the shapes, then take them out of what is drawn (destination-out): works on
        // every target, where a COPY primitive blend does not.
        if (s->eraseList || FAILED(s->dc->CreateCommandList(&s->eraseList))) return;
        s->dc->GetTarget(&s->eraseTarget);
        s->dc->SetTarget(s->eraseList.Get());
        return;
    }
    if (!s->eraseList) return;
    s->dc->SetTarget(s->eraseTarget.Get());
    s->eraseList->Close();
    D2D1_MATRIX_3X2_F transform;
    s->dc->GetTransform(&transform);
    s->dc->SetTransform(D2D1::Matrix3x2F::Identity());
    s->dc->DrawImage(s->eraseList.Get(), D2D1_INTERPOLATION_MODE_LINEAR, D2D1_COMPOSITE_MODE_DESTINATION_OUT);
    s->dc->SetTransform(transform);
    s->eraseList.Reset();
    s->eraseTarget.Reset();
}

int bp_write_png(const uint16_t *path, int width, int height, const uint8_t *pixels) {
    if (!g.wic && FAILED(bp_graphics_start())) return -1;
    if (!g.wic) return -1;
    ComPtr<IWICBitmap> bitmap;
    if (FAILED(g.wic->CreateBitmapFromMemory(width, height, GUID_WICPixelFormat32bppPBGRA, width * 4, width * height * 4,
                                             const_cast<BYTE *>(pixels), &bitmap))) return -1;
    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapEncoder> encoder;
    ComPtr<IWICBitmapFrameEncode> frame;
    if (FAILED(g.wic->CreateStream(&stream)) ||
        FAILED(stream->InitializeFromFilename(reinterpret_cast<const wchar_t *>(path), GENERIC_WRITE)) ||
        FAILED(g.wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) ||
        FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache)) ||
        FAILED(encoder->CreateNewFrame(&frame, nullptr)) || FAILED(frame->Initialize(nullptr)) ||
        FAILED(frame->SetSize(width, height))) return -1;
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    if (FAILED(frame->SetPixelFormat(&format))) return -1;
    // The PNG encoder takes straight alpha: WriteSource converts from the premultiplied bitmap.
    if (FAILED(frame->WriteSource(bitmap.Get(), nullptr)) || FAILED(frame->Commit()) || FAILED(encoder->Commit())) return -1;
    return 0;
}

void *bp_make_icon(int size, BPIconDrawer draw, void *context) {
    std::vector<uint8_t> pixels(static_cast<size_t>(size) * size * 4);
    if (bp_render_pixels(size, size, 1, draw, context, pixels.data()) != 0) return nullptr;
    BITMAPV5HEADER header = {};
    header.bV5Size = sizeof(header);
    header.bV5Width = size;
    header.bV5Height = -size;  // top-down
    header.bV5Planes = 1;
    header.bV5BitCount = 32;
    header.bV5Compression = BI_BITFIELDS;
    header.bV5RedMask = 0x00FF0000;
    header.bV5GreenMask = 0x0000FF00;
    header.bV5BlueMask = 0x000000FF;
    header.bV5AlphaMask = 0xFF000000;
    void *bits = nullptr;
    HDC screen = GetDC(nullptr);
    HBITMAP color = CreateDIBSection(screen, reinterpret_cast<BITMAPINFO *>(&header), DIB_RGB_COLORS, &bits, nullptr, 0);
    ReleaseDC(nullptr, screen);
    if (!color || !bits) return nullptr;
    std::memcpy(bits, pixels.data(), pixels.size());
    HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
    ICONINFO info = {};
    info.fIcon = TRUE;
    info.hbmColor = color;
    info.hbmMask = mask;
    HICON icon = CreateIconIndirect(&info);
    DeleteObject(color);
    DeleteObject(mask);
    return icon;
}

}  // extern "C"

import SwiftUI
import BreakpointRuntime

// The app icon, drawn in code and rendered to an
// .iconset by `BreakpointSnapshots --app-icon` during scripts/build-app.sh.

/// The app icon: a macOS-grid rounded square (824/1024 of the canvas, radius 185) in the
/// Breakpoint gradient, with the white brand mark. Draw at any square size.
///
/// Small sizes are drawn, not just scaled: below 48 px the mark grows and its eyes get larger so
/// they survive the pixel grid; below 24 px the two eyes merge into one slot and the sheen, rim
/// and shadows are dropped, so the 16 px icon stays a crisp white tag.
public struct AppIconView: View {
    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let detail = AppIconDetail(side: side)
            let body = side * 824 / 1024
            let radius = side * 185 / 1024
            let tile = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                tile
                    .fill(Theme.Colors.brandGradient)
                    .overlay {
                        if detail != .tiny {
                            // A soft top sheen and a faint lower shade give the tile depth.
                            tile.fill(LinearGradient(stops: [
                                .init(color: .white.opacity(0.20), location: 0),
                                .init(color: .white.opacity(0), location: 0.45),
                                .init(color: .black.opacity(0.08), location: 1),
                            ], startPoint: .top, endPoint: .bottom))
                        }
                    }
                    .overlay {
                        if detail == .full {
                            tile.strokeBorder(Color.white.opacity(0.22), lineWidth: max(1, side / 512))
                        }
                    }
                    .frame(width: body, height: body)
                    .shadow(color: .black.opacity(detail == .tiny ? 0 : 0.28),
                            radius: side * 10 / 1024, x: 0, y: side * 10 / 1024)
                AppIconGlyph(detail: detail)
                    .fill(Color.white, style: FillStyle(eoFill: false))
                    .frame(width: body * detail.markWidth, height: body * detail.markWidth / BrandMarkShape.aspectRatio)
                    .shadow(color: Color(hex: 0x10204A).opacity(detail == .full ? 0.25 : 0),
                            radius: side * 6 / 1024, x: 0, y: side * 4 / 1024)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Breakpoint")
    }
}

/// How much detail the icon carries at a size.
enum AppIconDetail: Equatable {
    /// ≥ 48 px: the brand mark as drawn everywhere else, with sheen, rim and shadows.
    case full
    /// 24–47 px: larger mark, larger eyes.
    case small
    /// < 24 px: larger mark, one slot instead of two eyes, flat.
    case tiny

    init(side: CGFloat) {
        self = side >= 48 ? .full : (side >= 24 ? .small : .tiny)
    }

    /// Mark width as a fraction of the tile.
    var markWidth: CGFloat {
        switch self {
        case .full: return 0.62
        case .small: return 0.68
        case .tiny: return 0.74
        }
    }
}

/// The brand mark for the icon: the tag with its eyes knocked out, with the eyes
/// simplified for small sizes. Uses the shared tag geometry (`BrandMarkShape`).
struct AppIconGlyph: Shape {
    var detail: AppIconDetail

    func path(in rect: CGRect) -> Path {
        let tag = BrandMarkShape(.tag).path(in: rect)
        let s = BrandMarkShape.scale(in: rect)
        // Grid → points, matching BrandMarkShape's centring.
        let originX = rect.midX - 21.5 * s / 2 - 1.25 * s
        let originY = rect.midY - 13.5 * s / 2 - 5.25 * s
        func grid(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: originX + x * s, y: originY + y * s, width: w * s, height: h * s)
        }
        var notch = Path()
        switch detail {
        case .full:
            notch = BrandMarkShape(.pauseBars).path(in: rect)
        case .small:
            // The eyes 3.6 × 4.2 (rather than 3 × 3.6), 1.4 apart, on the same centre line.
            notch.addEllipse(in: grid(5.7, 9.3, 3.6, 4.2))
            notch.addEllipse(in: grid(10.7, 9.3, 3.6, 4.2))
        case .tiny:
            notch.addRoundedRect(in: grid(7, 9, 6, 6), cornerSize: CGSize(width: 1.6 * s, height: 1.6 * s))
        }
        return tag.subtracting(notch)
    }
}

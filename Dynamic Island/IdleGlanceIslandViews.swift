import AppKit
import SwiftUI

/// Idle glance compact ↔ expanded in one tree — same morph pattern as Now Playing.
/// Shape size comes from `IslandMetrics` compact / expanded (not custom idle metrics).
struct IdleGlanceContent: View {
    @EnvironmentObject private var model: NotchViewModel

    var isExpanded: Bool
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var weather: IslandWeatherSnapshot?
    var destinations: [IslandIdleDestination]

    /// Compact shows two icons in the trailing strip; expanded fills a 2×2 grid.
    private var compactDestinations: [IslandIdleDestination] {
        Array(destinations.prefix(2))
    }

    private var expandedDestinations: [IslandIdleDestination] {
        let items = Array(destinations.prefix(4))
        if items.count >= 4 { return items }
        var filled = items
        for destination in IslandIdleDestination.allCases where !filled.contains(destination) {
            filled.append(destination)
            if filled.count >= 4 { break }
        }
        return filled
    }

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                Color.clear
                    .frame(height: IslandMetrics.expandedContentTopInset(notchHeight: notchHeight))
            }

            Group {
                if isExpanded {
                    expandedBody
                        .transition(IslandMetrics.contentReveal)
                } else {
                    compactBody
                }
            }
            .padding(.horizontal, isExpanded ? IslandMetrics.expandedHorizontalPadding : 0)
            .padding(
                .bottom,
                isExpanded && !model.showsShelfRow
                    ? IslandMetrics.expandedVerticalPadding
                    : 0
            )
            .frame(maxWidth: .infinity, maxHeight: isExpanded ? .infinity : .infinity, alignment: .top)

            if isExpanded, model.showsShelfRow {
                ShelfTray(
                    items: model.shelfItems,
                    isDropTargeted: model.isDropTargeted,
                    onTargeted: { model.setDropTargeted($0) },
                    onDrop: { model.handleShelfDrop(providers: $0) },
                    onRemove: model.removeShelfItem,
                    onDragBegan: model.beginShelfDrag,
                    onDragEnded: { id, completed in
                        model.endShelfDrag(itemID: id, completedOutside: completed)
                    }
                )
                .frame(height: IslandMetrics.shelfRowHeight)
                .padding(.top, IslandMetrics.shelfIslandGap)
                .padding(.horizontal, IslandMetrics.expandedHorizontalPadding)
                .padding(.bottom, IslandMetrics.expandedVerticalPadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isExpanded ? .top : .center)
    }

    // MARK: Compact — content only in visible ears beside the camera

    private var compactBody: some View {
        let leftEar = IslandMetrics.idleGlanceCompactLeftEar
        let rightEar = IslandMetrics.idleGlanceCompactRightEar
        let cameraBand = max(notchWidth, 1)

        return HStack(spacing: 0) {
            compactWeather
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .frame(width: leftEar, alignment: .leading)
                .clipped()

            // Physical camera sits here — keep empty so live matches screenshots.
            Color.clear
                .frame(width: cameraBand)

            HStack(spacing: Self.compactMarkSpacing) {
                ForEach(compactDestinations, id: \.self) { destination in
                    destinationMark(destination, size: Self.compactMarkSize)
                }
            }
            .padding(.trailing, Self.compactTrailingPad)
            .frame(width: rightEar, alignment: .trailing)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactWeather: some View {
        HStack(spacing: 4) {
            appleWeatherIcon(size: 12)
            Text(weather?.temperatureLabel ?? "--°")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(compactWeatherAccessibility)
    }

    // MARK: Expanded — fits standard 335×178 shell

    private var expandedBody: some View {
        HStack(alignment: .center, spacing: 0) {
            weatherPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            IslandGradientDivider()
                .padding(.vertical, 4)
                .padding(.horizontal, 10)

            // Same flexible column as weather so shortcuts fill the right half.
            destinationGrid
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Same point size as the expanded weather SF Symbol / AQI gauge.
    private static let expandedGlyphSize: CGFloat = 16
    /// Shared number style for temperature and AQI in the expanded panel.
    private static let expandedValueFont = Font.system(size: 32, weight: .bold)
    /// Fixed value column so Weather / AQI label stacks share one left edge.
    private static let expandedValueColumnWidth: CGFloat = 52

    private var weatherPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            metricRow(
                icon: { appleWeatherIcon(size: Self.expandedGlyphSize) },
                value: {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(weather.map { "\($0.temperatureC)" } ?? "--")
                            .font(Self.expandedValueFont)
                            .foregroundStyle(.white)
                            .monospacedDigit()
                        Text("°")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            // Industry-standard superscript: sits at the top-right of the digits.
                            .baselineOffset(14)
                    }
                },
                title: "Weather",
                subtitle: weather?.conditionLabel ?? "Unavailable"
            )

            metricRow(
                icon: {
                    IslandAQIGauge(aqi: weather?.usAQI, size: Self.expandedGlyphSize)
                        .opacity(weather?.usAQI == nil ? 0.45 : 1)
                },
                value: {
                    Text(weather?.usAQI.map { "\($0)" } ?? "--")
                        .font(Self.expandedValueFont)
                        .foregroundStyle(aqiColor)
                        .monospacedDigit()
                        .opacity(weather?.usAQI == nil ? 0.35 : 1)
                },
                title: "AQI",
                subtitle: weather?.aqiCategory ?? "Unavailable"
            )
        }
        .frame(maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(expandedWeatherAccessibility)
    }

    private func metricRow<Icon: View, Value: View>(
        icon: () -> Icon,
        value: () -> Value,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            icon()
                .frame(width: Self.expandedGlyphSize, height: Self.expandedGlyphSize)

            value()
                .frame(width: Self.expandedValueColumnWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
        }
    }

    /// Multicolor SF Symbol — same family Apple Weather / WeatherKit use.
    private func appleWeatherIcon(size: CGFloat) -> some View {
        Image(systemName: weather?.conditionSymbolName ?? "cloud.sun.fill")
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.multicolor)
            .accessibilityHidden(true)
    }

    /// Compact ear marks — sized to sit evenly in the trailing ear.
    private static let compactMarkSize: CGFloat = 16
    private static let compactMarkSpacing: CGFloat = 8
    private static let compactTrailingPad: CGFloat = 8
    /// Expanded grid marks — same outer size for every destination.
    private static let expandedMarkSize: CGFloat = 28
    /// Equal row + column rhythm in the 2×2 grid.
    private static let destinationGridSpacing: CGFloat = 10

    private var destinationGrid: some View {
        let items = expandedDestinations
        let columns = [
            GridItem(.flexible(), spacing: Self.destinationGridSpacing, alignment: .center),
            GridItem(.flexible(), alignment: .center)
        ]
        return LazyVGrid(columns: columns, spacing: Self.destinationGridSpacing) {
            ForEach(items, id: \.self) { destination in
                destinationTile(destination)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func destinationTile(_ destination: IslandIdleDestination) -> some View {
        VStack(spacing: 6) {
            destinationMark(destination, size: Self.expandedMarkSize)

            Text(shortLabel(destination))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(destination.displayName)
    }

    /// Official logo in a shared app-icon squircle so every mark has the same
    /// outer height (YouTube Music’s full-bleed circle no longer reads taller).
    private func destinationMark(_ destination: IslandIdleDestination, size: CGFloat) -> some View {
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                if let asset = destination.logoAssetName,
                   NSImage(named: asset) != nil {
                    Image(asset)
                        .resizable()
                        .interpolation(.high)
                        .renderingMode(.original)
                        .scaledToFill()
                        .frame(width: size, height: size)
                } else {
                    Image(systemName: destination.systemImageName)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: size * 0.223, style: .continuous))
            .accessibilityHidden(true)
    }

    private var aqiColor: Color {
        guard let weather, weather.usAQI != nil else {
            return .white.opacity(0.35)
        }
        return weather.aqiIsElevated ? Color.orange : Color.white
    }

    /// Compact VoiceOver: temperature only — AQI is expanded-only.
    private var compactWeatherAccessibility: String {
        guard let weather else { return "Weather unavailable" }
        return weather.temperatureLabel
    }

    private var expandedWeatherAccessibility: String {
        guard let weather else { return "Weather unavailable" }
        var parts = [weather.temperatureLabel, weather.conditionLabel]
        if let aqi = weather.usAQI {
            parts.append("AQI \(aqi)")
        }
        if let category = weather.aqiCategory {
            parts.append(category)
        }
        return parts.joined(separator: ", ")
    }

    private func shortLabel(_ destination: IslandIdleDestination) -> String {
        switch destination {
        case .youtubeMusic: return "YT Music"
        case .chatgpt: return "ChatGPT"
        default: return destination.displayName
        }
    }
}

/// Apple Weather–style AQI dial: full EPA color arc + white needle.
/// Sized to match the expanded weather SF Symbol glyph.
struct IslandAQIGauge: View {
    var aqi: Int?
    /// Matches `appleWeatherIcon(size:)` in the expanded idle panel.
    var size: CGFloat = 16

    /// US AQI dial maps 0…300 across the semicircle (Apple Weather convention).
    private var progress: Double {
        guard let aqi else { return 0 }
        return min(max(Double(aqi) / 300.0, 0), 1)
    }

    /// EPA / Apple Weather category colors — saturated so they read on black.
    private static let bandColors: [Color] = [
        Color(red: 0.18, green: 0.80, blue: 0.30), // Good
        Color(red: 1.00, green: 0.85, blue: 0.10), // Moderate
        Color(red: 1.00, green: 0.55, blue: 0.00), // Sensitive
        Color(red: 0.95, green: 0.20, blue: 0.18), // Unhealthy
        Color(red: 0.58, green: 0.18, blue: 0.72)  // Very unhealthy+
    ]

    private var lineWidth: CGFloat { max(3.0, size * 0.28) }

    var body: some View {
        ZStack {
            // Color track — five visible bands via path trim (reliable vs Canvas arcs).
            ForEach(0..<Self.bandColors.count, id: \.self) { index in
                let start = Double(index) / Double(Self.bandColors.count)
                let end = Double(index + 1) / Double(Self.bandColors.count)
                // Tiny gap so neighboring colors stay distinct.
                AQISemicircle()
                    .trim(from: start + 0.012, to: end - 0.012)
                    .stroke(
                        Self.bandColors[index],
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                    )
            }

            // Needle
            AQINeedle(progress: progress)
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: max(1.2, size * 0.1), lineCap: .round)
                )

            // Hub
            Circle()
                .fill(Color.white)
                .frame(width: max(2.5, size * 0.2), height: max(2.5, size * 0.2))
                .offset(y: size * 0.18)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Upper semicircle; trim 0 → left, trim 1 → right.
private struct AQISemicircle: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = min(rect.width, rect.height) * 0.16
        let radius = (min(rect.width, rect.height) / 2) - inset
        let center = CGPoint(x: rect.midX, y: rect.midY + radius * 0.35)
        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        return path
    }
}

private struct AQINeedle: Shape {
    var progress: Double

    func path(in rect: CGRect) -> Path {
        let inset = min(rect.width, rect.height) * 0.16
        let radius = (min(rect.width, rect.height) / 2) - inset
        let center = CGPoint(x: rect.midX, y: rect.midY + radius * 0.35)
        let angle = Angle.degrees(180 - progress * 180)
        let tipRadius = radius - inset * 0.15
        let tip = CGPoint(
            x: center.x + CGFloat(Foundation.cos(angle.radians)) * tipRadius,
            y: center.y - CGFloat(Foundation.sin(angle.radians)) * tipRadius
        )
        var path = Path()
        path.move(to: center)
        path.addLine(to: tip)
        return path
    }
}

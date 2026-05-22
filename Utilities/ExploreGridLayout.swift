import SwiftUI

/// 探索页网格：列数 2…4（中间宽度默认约 3 列）、间距 16pt。
enum ExploreGridLayout {
    static let spacing: CGFloat = 16

    /// `contentWidth` 为已扣除水平内边距后的可用宽度。
    static func columnCount(for contentWidth: CGFloat) -> Int {
        let w = max(0, contentWidth)
        let g = spacing
        // 列数越大，对单卡最小宽度要求略提高，避免过窄时仍挤 4 列；中间区间自然落在 3 列。
        let tiers: [(cols: Int, minCell: CGFloat)] = [
            (4, 210),
            (3, 195),
            (2, 160)
        ]
        for tier in tiers {
            let cell = (w - CGFloat(tier.cols - 1) * g) / CGFloat(tier.cols)
            if cell >= tier.minCell {
                return tier.cols
            }
        }
        return 2
    }

    static func columns(for contentWidth: CGFloat) -> [GridItem] {
        let n = columnCount(for: contentWidth)
        return Array(
            repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
            count: n
        )
    }
}

private struct ExploreColumnDistributionKey: Equatable {
    let itemCount: Int
    let version: Int
    let columnCount: Int
    let cardWidthUnits: Int
    let spacingUnits: Int
}

@MainActor
final class ExploreColumnDistributionCache<Item>: ObservableObject {
    private var cachedKey: ExploreColumnDistributionKey?
    private var cachedColumnIndices: [[Int]] = []

    func columns(
        for items: [Item],
        version: Int,
        columnCount: Int,
        cardWidth: CGFloat,
        spacing: CGFloat,
        height: (Item) -> CGFloat
    ) -> [[Item]] {
        let key = ExploreColumnDistributionKey(
            itemCount: items.count,
            version: version,
            columnCount: columnCount,
            cardWidthUnits: Int((cardWidth * 100).rounded()),
            spacingUnits: Int((spacing * 100).rounded())
        )

        if cachedKey != key {
            cachedKey = key
            cachedColumnIndices = distributeIndices(
                for: items,
                columnCount: columnCount,
                spacing: spacing,
                height: height
            )
        }

        return cachedColumnIndices.map { indices in
            indices.compactMap { index in
                guard items.indices.contains(index) else { return nil }
                return items[index]
            }
        }
    }

    func invalidate() {
        cachedKey = nil
        cachedColumnIndices = []
    }

    private func distributeIndices(
        for items: [Item],
        columnCount: Int,
        spacing: CGFloat,
        height: (Item) -> CGFloat
    ) -> [[Int]] {
        let safeColumnCount = max(1, columnCount)
        var columns: [[Int]] = Array(repeating: [], count: safeColumnCount)
        var columnHeights: [CGFloat] = Array(repeating: 0, count: safeColumnCount)

        for (index, item) in items.enumerated() {
            let itemHeight = max(1, height(item))
            let minHeight = columnHeights.min() ?? 0
            let column = columnHeights.firstIndex(of: minHeight) ?? 0
            columns[column].append(index)
            columnHeights[column] += itemHeight + spacing
        }

        return columns
    }
}

import SwiftUI

/// At most two single-line tag rows; reserve an ellipsis when tags overflow.
struct PlaylistSearchTagLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (index, frame) in layout.frames.enumerated() {
            if let frame {
                subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                     proposal: ProposedViewSize(frame.size))
            } else {
                // Omitted tags are outside the clipped layout, including the unused ellipsis.
                subviews[index].place(at: CGPoint(x: bounds.maxX + 1, y: bounds.maxY + 1),
                                     proposal: ProposedViewSize(width: 0, height: 0))
            }
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect?]) {
        let width = max(0, width)
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard let marker = sizes.last else { return (.zero, []) }
        let tagCount = sizes.count - 1
        var frames = [CGRect?](repeating: nil, count: sizes.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var row = 1

        func place(_ index: Int, width available: CGFloat) {
            let size = CGSize(width: max(0, min(sizes[index].width, available)), height: sizes[index].height)
            frames[index] = CGRect(x: x, y: y, width: size.width, height: size.height)
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        for index in 0..<tagCount {
            let ideal = sizes[index]
            if row == 1 && x > 0 && x + ideal.width > width {
                row = 2
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            if row == 2 {
                let remainingWidth = sizes[index..<tagCount].reduce(CGFloat.zero) { $0 + $1.width }
                    + CGFloat(tagCount - index - 1) * spacing
                if x + remainingWidth > width && index < tagCount - 1 {
                    let available = width - x - marker.width - spacing
                    if available < min(ideal.width, 20) {
                        place(tagCount, width: width - x)
                        break
                    }
                    place(index, width: available)
                    if ideal.width > available {
                        place(tagCount, width: width - x)
                        break
                    }
                    continue
                }
            }
            place(index, width: width - x)
        }
        return (CGSize(width: width.isFinite ? width : usedWidth, height: y + rowHeight), frames)
    }
}

import SwiftUI

/// Shared by playlist items and indexed search results.
struct PlaylistDeckLoadButtons: View {
    let deckNumbers: [Int]
    let isLoadedInDeck: (Int) -> Bool
    let onLoadToDeck: (Int) -> Void

    var body: some View {
        if deckNumbers.isEmpty {
            Text("No decks")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.2))
        } else {
            HStack(spacing: 3) {
                ForEach(deckNumbers, id: \.self) { number in
                    let active = isLoadedInDeck(number)
                    Button {
                        onLoadToDeck(number)
                    } label: {
                        Text("\(number)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(active ? .black : .cyan)
                            .frame(width: 22, height: 20)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(active ? Color.cyan : Color.cyan.opacity(0.1)))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(active ? Color.cyan : Color.cyan.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Load to Deck \(number)")
                }
            }
            .fixedSize()
        }
    }
}

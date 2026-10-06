import SwiftUI

/// A row of options in a pill-shaped track, the chosen one in yellow.
struct SegmentedPills<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let chosen = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(chosen ? Theme.onAccent : Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(chosen ? Theme.accent : .clear, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.raised, in: .capsule)
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

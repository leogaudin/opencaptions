import SwiftUI

/// A row of options in a pill-shaped track, the chosen one in yellow.
struct SegmentedPills<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> LocalizedStringKey
    /// Options that are part of Pro, shown with a lock; choosing one calls `onLocked` instead.
    var locked: (Value) -> Bool = { _ in false }
    var onLocked: () -> Void = {}

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let chosen = option == selection
                Button {
                    if locked(option) { onLocked() } else { selection = option }
                } label: {
                    HStack(spacing: 4) {
                        if locked(option) { Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold)) }
                        Text(label(option))
                    }
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

/// A choice among a few options as one line: the title, and the chosen option on the right with the
/// chevrons of a menu, the way a form's select looks. Quieter than `SegmentedPills`, which colours
/// a whole row in the accent.
struct InlinePicker<Value: Hashable>: View {
    let title: LocalizedStringKey
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> LocalizedStringKey

    var body: some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .medium))
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).tint(Theme.textPrimary)
        }
    }
}

/// A small "PRO" mark for what the free tier does not have.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .heavy)).tracking(0.5)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.accent, in: .capsule)
            .accessibilityLabel("Pro")
    }
}

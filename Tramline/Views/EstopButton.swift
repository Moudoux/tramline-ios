import SwiftUI

/// The emergency stop: held for 0.6 seconds while a ring fills, so a stray tap can't fire
/// it, but with nothing else to get through, as the GUI's is.
struct EstopButton: View {
    let fire: () -> Void
    var size: CGFloat = 44

    static let hold = 0.6

    @State private var pressing = false
    @State private var fired = 0

    var body: some View {
        ZStack {
            Circle().fill(Theme.bad.gradient)
            Circle()
                .trim(from: 0, to: pressing ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
            Text("STOP")
                .font(.system(size: size * 0.24, weight: .heavy))
                .tracking(0.5)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .scaleEffect(pressing ? 0.92 : 1)
        .contentShape(.circle)
        .onLongPressGesture(minimumDuration: Self.hold, maximumDistance: 40) {
            fired += 1
            fire()
        } onPressingChanged: { down in
            withAnimation(down ? .linear(duration: Self.hold) : .easeOut(duration: 0.15)) {
                pressing = down
            }
        }
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: fired)
        .sensoryFeedback(.selection, trigger: pressing) { _, down in down }
        .accessibilityElement()
        .accessibilityLabel("Emergency stop")
        .accessibilityHint("Touch and hold to stop the printer and turn its power off.")
        .accessibilityAddTraits(.isButton)
    }
}

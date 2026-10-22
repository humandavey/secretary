//
//  AnimatedButton.swift
//  secretary
//

import SwiftUI

struct AnimatedButton: View {
    @ObservedObject var speech: SpeechManager

    let totalMarks = 60
    let markWidth: CGFloat = 2
    let markLength: CGFloat = 30
    let circleRadius: CGFloat = 80
    let animationSpeed: Double = 2.0

    @State private var themeProgress: Double = 0.0

    var body: some View {
        VStack(spacing: 0) {
            Button {
                speech.toggleListening()
            } label: {
                TimelineView(.animation) { timeline in
                    ZStack {
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        let waveOffset = time * animationSpeed

                        ForEach(0..<totalMarks, id: \.self) { index in
                            let angle = Double(index) * (2.0 * .pi / Double(totalMarks))
                            let wave = sin(angle - waveOffset)
                            let pulseFactor = max(0, wave)
                            let dynamicLength = markLength + (pulseFactor * 5)

                            let baseColor = Color.blue.mix(with: .orange, by: themeProgress)
                            let peakColor = Color.purple.mix(with: .red, by: themeProgress)

                            RoundedRectangle(cornerRadius: markWidth / 2)
                                .fill(baseColor.mix(with: peakColor, by: pulseFactor))
                                .frame(width: markWidth, height: dynamicLength)
                                .offset(y: -circleRadius)
                                .rotationEffect(.degrees(Double(index) * (360.0 / Double(totalMarks))))
                        }

                        Image(systemName: speech.isRecording ? "pause.fill" : "play.fill")
                            .imageScale(.large)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: (circleRadius + markLength) * 2, height: (circleRadius + markLength) * 2)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)

            if speech.isRecording {
                Text(speech.transcribedText.isEmpty ? "Listening..." : speech.transcribedText)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(speech.transcribedText.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 220)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                    .padding(.top, 16)
            }
        }
        .animation(.easeOut(duration: 0.2), value: speech.transcribedText)
        .animation(.easeOut(duration: 0.2), value: speech.isRecording)
        .onChange(of: speech.isRecording) { _, newValue in
            withAnimation(.easeInOut(duration: 0.4)) {
                themeProgress = newValue ? 1.0 : 0.0
            }
        }
    }
}

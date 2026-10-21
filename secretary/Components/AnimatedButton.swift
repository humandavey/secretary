//
//  AnimatedButton.swift
//  secretary
//
//  Created by Davey Adams on 10/21/26.
//

import SwiftUI

struct AnimatedButton: View {
    let totalMarks = 60
    let markWidth: CGFloat = 2
    let markLength: CGFloat = 30
    let circleRadius: CGFloat = 80
    let animationSpeed: Double = 2.0
    
    @StateObject private var speechManager = SpeechManager()
    @State private var themeProgress: Double = 0.0
    @State private var listening: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                listening.toggle()
                speechManager.toggleListening()
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
                        
                        Image(systemName: listening ? "pause.fill" : "play.fill")
                            .imageScale(.large)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: (circleRadius + markLength) * 2, height: (circleRadius + markLength) * 2)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            
            Group {
                if listening {
                    Text(speechManager.transcribedText.isEmpty ? "Listening..." : speechManager.transcribedText)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundColor(speechManager.transcribedText.isEmpty ? .secondary : .primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 220)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .padding(.top, 16)
                }
            }
            .animation(.easeOut(duration: 0.2), value: speechManager.transcribedText)
            .animation(.easeOut(duration: 0.2), value: listening)

            Spacer()
        }
        .onChange(of: listening) { _, newValue in
            withAnimation(.easeInOut(duration: 0.4)) {
                themeProgress = newValue ? 1.0 : 0.0
            }
        }
    }
}

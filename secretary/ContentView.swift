//
//  ContentView.swift
//  secretary
//
//  Created by Davey Adams on 10/21/26.
//

import SwiftUI
import Foundation

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Secretary")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "xmark")
                }
                .keyboardShortcut("q")
            }
            
            Divider()
            
            AnimatedButton()
        }
        .padding()
        .frame(width: 260)
    }
}

import SwiftUI

struct ScreenContainer<Content: View>: View {
    
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        ZStack {
            
            // Background gradient fills entire screen
            Brand.pageGradient
                .ignoresSafeArea()
            
            VStack(alignment: .leading, spacing: 16) {
                
                // Header pinned to safe area
                ScreenHeader(title: title)
                
                // Scrollable content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        content
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 30)
                }
            }
        }
    }
}//
//  ScreenContainer.swift
//  BookadinkV2
//
//  Created by Brayden Kelly on 9/3/2026.
//


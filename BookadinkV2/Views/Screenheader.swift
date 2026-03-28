import SwiftUI

struct ScreenHeader: View {
    let title: String
    
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.primaryText)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }
}//
//  Screenheader.swift
//  BookadinkV2
//
//  Created by Brayden Kelly on 9/3/2026.
//


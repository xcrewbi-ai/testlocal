//
//  ContentView.swift
//  Geranium
//
//  Created by Constantin Clerc on 10/12/2023.
//

import SwiftUI

struct ContentView: View {
    @State var defaultTab = 1
    var body: some View {
        TabView(selection: $defaultTab) {
            LocSimView()
                .tabItem {
                    Label("GPS", systemImage: "location.fill")
                }
                .tag(1)
            CleanerView()
                .tabItem {
                    Label("Dọn dẹp", systemImage: "trash.fill")
                }
                .tag(2)
        }
    }
}

//
//  SettingsView.swift
//  Geranium
//
//  Created by cclerc on 23.12.23.
//

import SwiftUI
import AlertKit

struct SettingsView: View {
    @State var MinimCal: String = ""
    @State var LocSimTries: String = ""
    @StateObject private var appSettings = AppSettings()
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Label("Cleaner Settings", systemImage: "trash"), footer: Text("Various settings for the cleaner.")) {
                    Toggle(isOn: $appSettings.keepCheckBoxesC) {
                        Text("Keep selection after cleaning")
                    }
                    Toggle(isOn: $appSettings.getSizes) {
                        Text("Calculate Cleaning Size")
                    }
                    .onChange(of: appSettings.getSizes) { newValue in
                        UIApplication.shared.confirmAlert(title: "You need to quit the app to apply changes.", body: "You might want to open it back.", onOK: {
                            exitGracefully()
                        }, noCancel: true)
                    }
                    Toggle(isOn: Binding<Bool>(
                        get: { !appSettings.tmpClean },
                        set: { appSettings.tmpClean = !$0 }
                    )) {
                        Text("Safe Clean Measures (Enable this if on iOS 15!)")
                    }
                    .onChange(of: appSettings.tmpClean) { newValue in
                        UIApplication.shared.confirmAlert(title: "You need to quit the app to apply changes.", body: "You might want to open it back.", onOK: {
                            exitGracefully()
                        }, noCancel: true)
                    }
                }
                Section(header: Label("GPS Settings", systemImage: "location.fill.viewfinder"), footer: Text("Various settings for GPS simulation.")) {
                    Toggle(isOn: $appSettings.locSimMultipleAttempts) {
                        Text("Try stopping GPS multiple times")
                    }
                    if appSettings.locSimMultipleAttempts {
                        HStack {
                            Text("Minimum Attempts:")
                            Spacer()
                            TextField("3", text: $LocSimTries)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        .onAppear {
                            LocSimTries = "\(appSettings.locSimAttemptNB)"
                        }
                        .onChange(of: LocSimTries) { newValue in
                            appSettings.locSimAttemptNB = Int(LocSimTries) ?? 1
                        }
                    }
                }
            }
            .navigationTitle("Cài đặt")
        }
    }
}

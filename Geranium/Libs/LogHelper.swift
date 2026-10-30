//
//  LogHelper.swift
//  Geranium
//
//  Created by cclerc on 18.01.24.
//

import Foundation
import UIKit

func sendLog(_ logMessage: String, isAnalystic: Bool = false) {
    // Completely disabled
}

func getDeviceCode() -> String? {
    var systemInfo = utsname()
    uname(&systemInfo)
    let modelCode = withUnsafePointer(to: &systemInfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) {
            ptr in String.init(validatingUTF8: ptr)
        }
    }
    return modelCode
}

//
//  InstallActivity.swift
//  CompassPro
//

import Foundation

final class InstallActivity {
    static let shared = InstallActivity()
    
    enum Outcome {
        case installed
        case failed
        case cancelled
        case stopped
    }
    
    func runStarted() {}
    func runEnded(_ outcome: Outcome) {}
    func endLeftovers() {}
}

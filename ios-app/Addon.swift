//
//  Addon.swift
//  CompassPro
//

import Foundation
import SwiftUI
import Combine
import UIKit

class AppSettings: ObservableObject {
    @AppStorage("TSBypass") var tsBypass: Bool = false
    @AppStorage("UPDBypass") var updBypass: Bool = true
    @AppStorage("isLoggingAllowed") var loggingAllowed: Bool = false
    @AppStorage("isFirstRun") var isFirstRun: Bool = false
    @AppStorage("minimSizeC") var minimSizeC: Double = 50.0
    @AppStorage("keepCheckBoxesC") var keepCheckBoxesC: Bool = true
    @AppStorage("LocSimAttempts") var locSimAttemptNB: Int = 1
    @AppStorage("locSimMultipleAttempts") var locSimMultipleAttempts: Bool = false
    @AppStorage("usrUUID") var usrUUID: String = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
    @AppStorage("languageCode") var languageCode: String = ""
    @AppStorage("defaultTab") var defaultTab: Int = 1
    @AppStorage("firstCleanerTime") var firstCleanerTime: Bool = false
    @AppStorage("tmpClean") var tmpClean: Bool = true
    @AppStorage("getSizes") var getSizes: Bool = false
}

var currentUIAlertController: UIAlertController?

extension UIApplication {
    func dismissAlert(animated: Bool = true) {
        DispatchQueue.main.async {
            currentUIAlertController?.dismiss(animated: animated)
        }
    }
    
    func alert(title: String = "Lỗi", body: String, animated: Bool = true, withButton: Bool = true) {
        DispatchQueue.main.async {
            currentUIAlertController = UIAlertController(title: title, message: body, preferredStyle: .alert)
            if withButton { currentUIAlertController?.addAction(.init(title: "OK", style: .cancel)) }
            self.present(alert: currentUIAlertController!)
        }
    }
    
    func confirmAlert(title: String = "Xác nhận", body: String, onOK: @escaping () -> Void, noCancel: Bool = false, onCancel: (() -> Void)? = nil, yes: Bool = false) {
        DispatchQueue.main.async {
            currentUIAlertController = UIAlertController(title: title, message: body, preferredStyle: .alert)
            if !noCancel {
                currentUIAlertController?.addAction(.init(title: "Hủy", style: .cancel, handler: { _ in
                    onCancel?()
                }))
            }
            
            let okActionTitle = yes ? "Có" : "OK"
            currentUIAlertController?.addAction(.init(title: okActionTitle, style: noCancel ? .cancel : .default, handler: { _ in
                onOK()
            }))
            
            self.present(alert: currentUIAlertController!)
        }
    }
    
    func TextFieldAlert(title: String, message: String? = nil, textFieldPlaceHolder: String, secondTextFieldPlaceHolder: String? = nil, completion: @escaping (String?, String?) -> Void) {
        DispatchQueue.main.async {
            let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
            
            alertController.addTextField { textField in
                textField.placeholder = textFieldPlaceHolder
            }
            
            if let secondPlaceholder = secondTextFieldPlaceHolder {
                alertController.addTextField { textField in
                    textField.placeholder = secondPlaceholder
                }
            }
            
            let okAction = UIAlertAction(title: "OK", style: .default) { _ in
                let firstText = alertController.textFields?.first?.text
                let secondText = (alertController.textFields?.count ?? 0) > 1 ? alertController.textFields?[1].text : nil
                completion(firstText, secondText)
            }
            
            let cancelAction = UIAlertAction(title: "Hủy", style: .cancel, handler: nil)
            alertController.addAction(okAction)
            alertController.addAction(cancelAction)
            
            self.present(alert: alertController)
        }
    }
    
    func present(alert: UIAlertController) {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        if var topController = windows.first(where: { $0.isKeyWindow })?.rootViewController ?? windows.first?.rootViewController {
            while let presentedViewController = topController.presentedViewController {
                topController = presentedViewController
            }
            topController.present(alert, animated: true)
        }
    }
}

func impactVibrate() {
    DispatchQueue.main.async {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.prepare()
        impact.impactOccurred()
    }
}

//
//  PairingView.swift
//  CompassPro
//
//  Dedicated Pairing View for iOS 17.2 / 27.2+
//  Focused exclusively on:
//  1. Manual pairing file import (.mobiledevicepairing / .plist)
//  2. VPN Loopback & DVT connection testing
//

import SwiftUI
import UniformTypeIdentifiers

struct PairingView: View {
    @Environment(Engine.self) private var engine
    @ObservedObject var bridge = LocationBridge.shared

    @State private var showPairingImporter = false
    @State private var isTestingConnection = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    @State private var showAlert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                headerCard

                // Status Card
                statusCard

                // Primary Action: Import Pairing File
                importCard

                // Secondary Action: Test Connection
                testConnectCard

                // Quick Guide
                guideCard
            }
            .padding(16)
        }
        .navigationTitle("Ghép đôi & Kết nối")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .sheet(isPresented: $showPairingImporter) {
            FileImporterRepresentableView(allowedContentTypes: UTType.pairingFileTypes) { urls in
                guard let url = urls.first else { return }
                Task {
                    await engine.importPairingFile(from: url)
                    if bridge.hasPairingFile {
                        alertTitle = "Thành công"
                        alertMessage = "Đã nạp tệp ghép đôi thành công! Thiết bị đã sẵn sàng kết nối."
                        showAlert = true
                    } else if let err = engine.lastError {
                        alertTitle = "Lỗi nạp tệp"
                        alertMessage = err
                        showAlert = true
                    }
                }
            }
            .ignoresSafeArea()
        }
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text(alertTitle),
                message: Text(alertMessage),
                dismissButton: .default(Text("Đã hiểu"))
            )
        }
        .onAppear {
            engine.refreshNetworkStatus()
        }
    }

    // MARK: - Subviews

    private var headerCard: some View {
        VStack(spacing: 8) {
            Image(systemName: bridge.hasPairingFile ? "checkmark.shield.fill" : "link.badge.plus")
                .font(.system(size: 46))
                .foregroundColor(bridge.hasPairingFile ? .green : .blue)
                .padding(.top, 8)

            Text(bridge.hasPairingFile ? "Thiết bị đã có tệp ghép đôi" : "Chưa có tệp ghép đôi")
                .font(.title3.bold())

            Text("Trên iOS 17.2 & 27.2, Apple yêu cầu tệp ghép đôi nhà phát triển (.mobiledevicepairing / .plist) để cho phép giả lập vị trí DVT.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack {
                Label("TRẠNG THÁI HỆ THỐNG", systemImage: "info.circle")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                Button("Làm mới") {
                    engine.refreshNetworkStatus()
                }
                .font(.caption)
            }

            Divider()

            // 1. Tệp ghép đôi
            HStack(spacing: 12) {
                Image(systemName: bridge.hasPairingFile ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(bridge.hasPairingFile ? .green : .orange)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Tệp ghép đôi (Pairing File)")
                        .font(.subheadline.bold())
                    if bridge.hasPairingFile {
                        Text(engine.importedPairingName ?? "rp_pairing_file.plist (Đã nạp)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Chưa nạp tệp")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                Spacer()
                if bridge.hasPairingFile {
                    Text("Sẵn sàng")
                        .font(.caption2.bold())
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                }
            }

            // 2. VPN Loopback
            HStack(spacing: 12) {
                Image(systemName: engine.vpnConnected ? "shield.lefthalf.filled" : "shield.slash.fill")
                    .foregroundColor(engine.vpnConnected ? .green : .red)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Đường hầm VPN Loopback")
                        .font(.subheadline.bold())
                    Text(engine.vpnConnected ? "Đã kết nối (10.7.0.1)" : "Đang tắt (Cần bật VPN SideStore / WireGuard)")
                        .font(.caption)
                        .foregroundColor(engine.vpnConnected ? .secondary : .red)
                }
                Spacer()
                Text(engine.vpnConnected ? "Đã bật" : "Cần bật")
                    .font(.caption2.bold())
                    .foregroundColor(engine.vpnConnected ? .green : .red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill((engine.vpnConnected ? Color.green : Color.red).opacity(0.12)))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("1. Nhập tệp ghép đôi", systemImage: "doc.badge.plus")
                .font(.headline)

            Text("Chọn tệp .mobiledevicepairing hoặc .plist từ máy (có thể xuất từ SideStore hoặc sao chép từ máy tính).")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: { showPairingImporter = true }) {
                HStack(spacing: 8) {
                    Image(systemName: bridge.hasPairingFile ? "arrow.triangle.2.circlepath.doc.on.clipboard" : "folder.fill")
                    Text(bridge.hasPairingFile ? "Thay thế tệp ghép đôi khác" : "Chọn tệp ghép đôi từ Tệp (Files)...")
                }
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var testConnectCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("2. Kiểm tra kết nối Fake GPS", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)

            Text("Kiểm tra xem thiết bị đã kết nối được tới dịch vụ giả lập vị trí DVT qua VPN hay chưa.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: runTestConnection) {
                HStack(spacing: 8) {
                    if isTestingConnection {
                        ProgressView().tint(.white)
                        Text("Đang kiểm tra kết nối...")
                    } else {
                        Image(systemName: "bolt.horizontal.circle.fill")
                        Text("Kiểm tra kết nối ngay")
                    }
                }
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(isTestingConnection)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hướng dẫn nhanh", systemImage: "lightbulb.fill")
                .font(.subheadline.bold())
                .foregroundColor(.orange)

            Text("• Bước 1: Mở app SideStore (hoặc Cài đặt > VPN) và gạt BẬT VPN lên.\n• Bước 2: Bấm nút 'Chọn tệp ghép đôi' ở trên để chọn file pair của bạn.\n• Bước 3: Bấm 'Kiểm tra kết nối ngay' để kiểm tra kết nối.\n• Bước 4: Chuyển sang tab 'La bàn GPS' ở thanh dưới cùng để bắt đầu Fake vị trí!")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineSpacing(4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - Actions

    private func runTestConnection() {
        guard !isTestingConnection else { return }
        isTestingConnection = true

        Task {
            do {
                try await bridge.ensureDVTReady()
                isTestingConnection = false
                alertTitle = "Kết nối thành công! 🟢"
                alertMessage = "Dịch vụ giả lập vị trí DVT đã kết nối thành công và Developer Disk Image đã sẵn sàng. Bạn có thể sang tab 'La bàn GPS' để dùng ngay!"
                showAlert = true
            } catch {
                isTestingConnection = false
                alertTitle = "Chưa thể kết nối 🔴"
                alertMessage = error.localizedDescription
                showAlert = true
            }
        }
    }
}

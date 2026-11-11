//
//  PairingSheetView.swift
//  CompassPro
//
//  Dedicated Pairing Sheet for iOS 17.2 / 27.2+
//  Supports:
//  - Wireless self-pairing (Settings > Developer > Connect) with PIN code display
//  - Manual .mobiledevicepairing / .plist import
//  - LocalDevVPN / Tunnel verification & DDI status
//

import SwiftUI
import UniformTypeIdentifiers

struct PairingSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var bridge = LocationBridge.shared
    @State private var isShowingFileImporter = false
    @State private var isPairingInProgress = false
    @State private var displayedPIN: String?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerSection
                    statusSummaryCard
                    wirelessPairingCard
                    manualImportCard
                    vpnAndDdiCard
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Ghép đôi & Nhà phát triển")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result: result)
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: bridge.hasPairingFile ? "checkmark.shield.fill" : "link.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(bridge.hasPairingFile ? .green : .blue)

            Text(bridge.hasPairingFile ? "Thiết bị đã ghép đôi" : "Ghép đôi để giả lập GPS trên iOS 17+")
                .font(.title3.bold())

            Text("Trên iOS 17.2 và 27.2, Apple yêu cầu kết nối chế độ nhà phát triển qua mạng nội bộ để cho phép giả lập vị trí mà không bị sandbox chặn.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var statusSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TRẠNG THÁI HỆ THỐNG")
                .font(.caption.bold())
                .foregroundColor(.secondary)

            statusRow(
                title: "Tệp ghép đôi (Pairing File)",
                status: bridge.hasPairingFile ? "Đã có" : "Chưa có",
                isOk: bridge.hasPairingFile,
                icon: "lock.doc.fill"
            )

            statusRow(
                title: "Ảnh đĩa Apple (DDI)",
                status: DeveloperDiskImage.isDownloaded ? "Đã tải xong" : "Tự động tải khi chạy",
                isOk: DeveloperDiskImage.isDownloaded,
                icon: "externaldrive.fill"
            )

            statusRow(
                title: "Đường hầm LocalDevVPN",
                status: bridge.isTunnelAvailable ? "Đang kết nối" : "Cần bật VPN",
                isOk: bridge.isTunnelAvailable,
                icon: "shield.lefthalf.filled"
            )
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func statusRow(title: String, status: String, isOk: Bool, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(isOk ? .green : .orange)
                .frame(width: 24)
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(status)
                .font(.caption.bold())
                .foregroundColor(isOk ? .green : .secondary)
        }
    }

    private var wirelessPairingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Cách 1: Tự động ghép đôi qua Cài đặt", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)

            Text("Phù hợp với iOS 17.4+ & 27.2 có mục Chế độ nhà phát triển trong Cài đặt.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let pin = displayedPIN {
                VStack(spacing: 8) {
                    Text("MÃ PIN GHÉP ĐÔI CỦA BẠN:")
                        .font(.caption.bold())
                        .foregroundColor(.blue)

                    Text(pin)
                        .font(.system(size: 38, weight: .heavy, design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 20)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.12)))

                    Text("1. Mở Cài đặt > Quyền riêng tư & Bảo mật > Nhà phát triển\n2. Nhấn vào 'Kết nối / Ghép đôi thiết bị'\n3. Chọn máy và nhập 6 chữ số trên.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Button {
                startWirelessPairing()
            } label: {
                HStack {
                    if isPairingInProgress {
                        ProgressView().tint(.white)
                        Text("Đang mở điểm ghép đôi...")
                    } else {
                        Image(systemName: "bolt.fill")
                        Text(bridge.hasPairingFile ? "Ghép đôi lại (Regenerate)" : "Bắt đầu ghép đôi tự động")
                    }
                }
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue))
                .foregroundColor(.white)
            }
            .disabled(isPairingInProgress)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var manualImportCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Cách 2: Nhập tệp Pair thủ công", systemImage: "doc.badge.plus")
                .font(.headline)

            Text("Nếu bạn đã có tệp .mobiledevicepairing hoặc .plist từ máy tính (Jitterbugpair, pymobiledevice3, SideStore...), bạn có thể chọn trực tiếp.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                isShowingFileImporter = true
            } label: {
                HStack {
                    Image(systemName: "folder.fill")
                    Text("Chọn tệp .mobiledevicepairing từ máy...")
                }
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12).stroke(Color.blue, lineWidth: 1.5))
                .foregroundColor(.blue)
            }

            if let msg = statusMessage {
                Text(msg)
                    .font(.caption.bold())
                    .foregroundColor(.green)
            }
            if let err = errorMessage {
                Text(err)
                    .font(.caption.bold())
                    .foregroundColor(.red)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var vpnAndDdiCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Lưu ý về VPN Loopback", systemImage: "info.circle.fill")
                .font(.subheadline.bold())

            Text("Để ứng dụng gửi tín hiệu vị trí qua cổng cục bộ (127.0.0.1 hoặc 10.7.0.1) trên iOS 17+, cần cài đặt và bật cấu hình VPN LocalDevVPN hoặc WireGuard đi kèm.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - Actions

    private func startWirelessPairing() {
        guard !isPairingInProgress else { return }
        isPairingInProgress = true
        errorMessage = nil
        statusMessage = nil

        Task {
            do {
                _ = try await PairingController.shared.startAndWait()
                statusMessage = "Ghép đôi thành công! Thiết bị đã sẵn sàng giả lập vị trí."
                displayedPIN = nil
            } catch is CancellationError {
                // Cancelled
            } catch {
                errorMessage = "Lỗi ghép đôi: \(error.localizedDescription)"
            }
            isPairingInProgress = false
        }
    }

    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Không có quyền truy cập tệp đã chọn."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            Task {
                await Engine.shared.importPairingFile(from: url)
                if bridge.hasPairingFile {
                    statusMessage = "Đã nhập tệp ghép đôi thành công!"
                    errorMessage = nil
                } else {
                    errorMessage = "Tệp không hợp lệ hoặc thiếu thông tin ghép đôi."
                }
            }
        case .failure(let error):
            errorMessage = "Không thể đọc tệp: \(error.localizedDescription)"
        }
    }
}

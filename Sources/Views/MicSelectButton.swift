import SwiftUI
import CoreAudio

struct MicSelectButton: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showPopover = false
    @State private var inputDevices: [AudioInputDevice] = []

    var body: some View {
        DarkButton(
            icon: "mic.fill",
            isActive: settings.selectedInputDeviceID != nil
        ) {
            inputDevices = MicCaptureService.listInputDevices()
            showPopover.toggle()
        }
        .popover(isPresented: $showPopover) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio Input")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)

                DeviceRow(
                    name: "System Default",
                    isSelected: settings.selectedInputDeviceID == nil
                ) {
                    settings.selectedInputDeviceID = nil
                    showPopover = false
                }

                Divider().padding(.horizontal, 8)

                ForEach(inputDevices) { device in
                    DeviceRow(
                        name: device.name,
                        isSelected: settings.selectedInputDeviceID == device.id
                    ) {
                        settings.selectedInputDeviceID = device.id
                        showPopover = false
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(minWidth: 200)
        }
    }
}

private struct DeviceRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                    .foregroundColor(isSelected ? .cyan : .secondary)

                Text(name)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isHovering ? Color.white.opacity(0.06) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onHover { h in isHovering = h }
        .padding(.horizontal, 4)
    }
}

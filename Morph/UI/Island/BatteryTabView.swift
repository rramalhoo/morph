import SwiftUI

/// Every battery Morph can vouch for. A device without a reliable value shows only what's known.
struct BatteryTabView: View {
    @Environment(BatteryService.self) private var battery
    @Environment(VolumeService.self) private var output
    @Environment(DeviceBatteryService.self) private var devices
    @Environment(MorphPreferences.self) private var preferences

    private var rows: [PowerDevice] {
        PowerDevice.list(mac: preferences.batteryEnabled ? battery.snapshot : nil, audio: output.connectedBluetooth,
                         currentOutputUID: output.output?.device.uid, peripherals: devices.peripherals,
                         showsAudio: preferences.batteryAudioDevices, showsPeripherals: preferences.peripheralBattery)
    }

    private var list: some View {
        VStack(spacing: MorphSpacing.s) {
            ForEach(rows) { PowerDeviceRow(device: $0) }
        }
    }

    var body: some View {
        MorphCard {
            if rows.isEmpty {
                Text("No devices with a battery to show")
                    .font(MorphFont.secondary)
                    .foregroundStyle(MorphColor.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ViewThatFits(in: .vertical) {
                    list
                    ScrollView(.vertical, showsIndicators: false) { list }
                }
            }
        }
        .onAppear { devices.isVisible = true }
        .onDisappear { devices.isVisible = false }
    }
}

private struct PowerDeviceRow: View {
    let device: PowerDevice

    private var tint: Color {
        if device.isCharging == true { return MorphColor.positive }
        if let percentage = device.percentage, percentage <= 20 { return MorphColor.warning }
        return MorphColor.textPrimary
    }

    var body: some View {
        HStack(spacing: MorphSpacing.m) {
            Image(systemName: device.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MorphColor.textSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(MorphFont.secondary).foregroundStyle(MorphColor.textPrimary)
                Text(device.status).font(MorphFont.label).foregroundStyle(MorphColor.textSecondary)
            }
            .lineLimit(1)
            Spacer(minLength: MorphSpacing.s)
            if device.isCharging == true {
                Image(systemName: "bolt.fill").font(MorphFont.label).foregroundStyle(MorphColor.positive)
            }
            if let percentage = device.percentage {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(MorphColor.surfaceSecondary)
                        Capsule().fill(tint).frame(width: proxy.size.width * CGFloat(percentage) / 100)
                    }
                }
                .frame(width: 44, height: 4)
                Text("\(percentage)%")
                    .font(MorphFont.compact)
                    .foregroundStyle(MorphColor.textPrimary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([device.name, device.percentage.map { "\($0) percent" }, device.status].compactMap { $0 }.joined(separator: ", "))
    }
}

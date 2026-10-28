import SwiftUI

struct ConnectionView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var token = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connection")
                            .font(.system(size: 34, weight: .bold)).tracking(-1.5)
                        Text("Read usage directly from your Mac.")
                            .font(.system(size: 14)).lineSpacing(4).foregroundStyle(Palette.muted)
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            Eyebrow(text: "Mac address")
                            TextField("sandford.local:8037", text: $address)
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .accessibilityIdentifier("mac-address")
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Eyebrow(text: "Pairing key")
                            SecureField("Paste from your Mac", text: $token)
                                .accessibilityIdentifier("pairing-key")
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 16))
                    .padding(.vertical, 16)
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12)).foregroundStyle(Palette.rust).lineSpacing(3)
                            .accessibilityIdentifier("connection-error")
                    }
                    Button {
                        isConnecting = true
                        error = nil
                        Task {
                            defer { isConnecting = false }
                            do {
                                try await store.connect(address: address, token: token)
                                dismiss()
                            } catch {
                                self.error = (error as? URLError) == nil ? error.localizedDescription : store.friendlyError(error)
                            }
                        }
                    } label: {
                        HStack {
                            Text(isConnecting ? "Connecting…" : "Connect to Mac")
                            Spacer()
                            if isConnecting { ProgressView().tint(Palette.card) }
                            else { Image(systemName: "arrow.up.right") }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .padding(20)
                        .foregroundStyle(Palette.card)
                        .background(Palette.accent)
                    }
                    .disabled(isConnecting || address.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("connect-to-mac")
                    VStack(alignment: .leading, spacing: 18) {
                        Eyebrow(text: "On your Mac")
                        step("01", "Open Token Watch → Options → Local API.")
                        step("02", "Enable the API and Share with iPhone. Copy the address and pairing key above.")
                        step("03", "Keep both devices on the same trusted network.")
                    }
                    Text("Refreshes every minute while open and reconnects automatically. Last readings are saved offline. Provider logins stay on your Mac.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                }
                .padding(24)
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            .background(Palette.reset.ignoresSafeArea())
            .foregroundStyle(Palette.ink)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.disabled(isConnecting)
                }
            }
            .toolbarBackground(Palette.reset, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.reset)
        .interactiveDismissDisabled(isConnecting)
        .onAppear {
            address = store.connection?.address ?? ""
            token = store.connection?.token ?? ""
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.rust).padding(.top, 2)
            Text(text).font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(4)
        }
    }
}

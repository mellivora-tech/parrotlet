import SwiftUI
import AppKit

struct ProviderSetupView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selectedPreset: ProviderPreset
    @State private var draft: ProviderConfig
    @State private var showAdvanced = false
    @State private var connectionError: UserFacingError?
    @FocusState private var keyFocused: Bool
    private let showsPresetPicker: Bool
    private let connectButtonKey: L10n.Key
    private let onConnected: (() -> Void)?

    init(preset: ProviderPreset, provider: ProviderConfig,
         showsPresetPicker: Bool = true,
         connectButtonKey: L10n.Key = .connectAndStart,
         onConnected: (() -> Void)? = nil) {
        self.showsPresetPicker = showsPresetPicker
        self.connectButtonKey = connectButtonKey
        self.onConnected = onConnected
        _selectedPreset = State(initialValue: preset)
        _draft = State(initialValue: provider)
    }

    private var isConnecting: Bool {
        env.settings.testing[draft.id] == true
    }

    private var endpointError: APIEndpoint.ValidationError? {
        do {
            _ = try APIEndpoint.validate(draft.baseURL)
            return nil
        } catch let error as APIEndpoint.ValidationError {
            return error
        } catch {
            return .invalid
        }
    }

    private var requiresAPIKey: Bool {
        (try? APIEndpoint.validate(draft.baseURL))?.isLocal != true
    }

    private var canConnect: Bool {
        let hasKey = !(draft.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isConnecting && endpointError == nil
            && !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!requiresAPIKey || hasKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(env.t(.setupTitle))
                .eaFont(16, .title3, weight: .semibold)

            if showsPresetPicker {
                HStack(spacing: 8) {
                    ForEach(ProviderPreset.all) { preset in
                        Button {
                            selectedPreset = preset
                            draft = env.settings.setupDraft(for: preset)
                            connectionError = nil
                        } label: {
                            HStack(spacing: 6) {
                                providerIcon(preset)
                                Text(preset.defaultName)
                                    .eaFont(11, .callout, weight: .medium)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .background(
                                selectedPreset == preset ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selectedPreset == preset ? Color.accentColor : .secondary.opacity(0.25))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isConnecting)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("API Key")
                        .eaFont(12, .callout, weight: .medium)
                    Spacer()
                    Link(env.t(.getAPIKey), destination: selectedPreset.apiKeyURL)
                        .eaFont(11, .callout)
                }
                SecureField(env.t(.setupKeyPlaceholder), text: Binding(
                    get: { draft.apiKey ?? "" },
                    set: {
                        draft.apiKey = $0.nilIfBlank
                        connectionError = nil
                    }
                ))
                .textFieldStyle(.plain)
                .eaFont(13)
                .focused($keyFocused)
                .disabled(isConnecting)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 6) {
                Text(env.t(.model))
                    .foregroundStyle(.secondary)
                Text(draft.model.isEmpty ? "—" : draft.model)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    showAdvanced.toggle()
                } label: {
                    Label(env.t(.advancedSettings), systemImage: showAdvanced ? "chevron.up" : "chevron.down")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
            }
            .eaFont(11, .callout)
            .foregroundStyle(.secondary)

            if showAdvanced {
                VStack(spacing: 8) {
                    advancedField(env.t(.name), text: $draft.name)
                    advancedField("Base URL", text: $draft.baseURL)
                    advancedField(env.t(.model), text: $draft.model)
                }
                .disabled(isConnecting)
                if let endpointError {
                    Text(env.t(endpointError.l10nKey))
                        .eaFont(11, .callout)
                        .foregroundStyle(.red)
                }
            }

            if let connectionError {
                Text(connectionError.message)
                    .eaFont(11, .callout)
                    .foregroundStyle(connectionError.style == .guidance ? Color.accentColor : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task {
                    connectionError = nil
                    let failure = await env.settings.connectAndActivate(draft)
                    if let failure {
                        connectionError = failure
                        if failure.detail == "HTTP 404" {
                            showAdvanced = true
                        } else if failure.style == .guidance {
                            keyFocused = true
                        }
                    } else {
                        onConnected?()
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    }
                    Text(env.t(isConnecting ? .connecting : connectButtonKey))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canConnect)

            VStack(alignment: .leading, spacing: 3) {
                Text(env.t(.setupPrivacy))
                Text(env.t(.setupTestNote))
            }
            .eaFont(10, .caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.primary.opacity(0.06))
        }
    }

    private func advancedField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .eaFont(11, .callout)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            TextField("", text: text)
                .labelsHidden()
                .textFieldStyle(.plain)
                .eaFont(11, .callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private func providerIcon(_ preset: ProviderPreset) -> some View {
        if let image = NSImage(named: "provider-\(preset.id)") {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "globe")
                .frame(width: 18, height: 18)
        }
    }
}

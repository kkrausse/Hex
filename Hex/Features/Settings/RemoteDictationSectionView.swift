import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// Fork addition: points live dictation at a dictation server instead of the
/// on-device streaming model.
///
/// A switch beside the model list rather than an entry in it, because the
/// server is not a model Hex can download, load, or delete — and because the
/// selected model keeps a job when this is on: it is what transcribes the
/// recording if the server cannot.
struct RemoteDictationSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	private var addressIsUsable: Bool {
		RemoteDictationEndpoint.streamURL(from: store.hexSettings.remoteDictationURL) != nil
	}

	var body: some View {
		Section("Live Dictation Server") {
			Label {
				Toggle(
					"Dictate through a server",
					isOn: Binding(
						get: { store.hexSettings.remoteDictationEnabled },
						set: { store.send(.setRemoteDictationEnabled($0)) }
					)
				)
				Text("Text appears as you speak, transcribed by your own dictation server instead of this Mac. If the server cannot be reached, the recording is transcribed with the model selected above.")
			} icon: {
				Image(systemName: "server.rack")
			}

			Label {
				TextField(
					"Server address",
					text: Binding(
						get: { store.hexSettings.remoteDictationURL },
						set: { store.send(.setRemoteDictationURL($0)) }
					),
					prompt: Text("https://your-server.example.ts.net:9876")
				)
				.textFieldStyle(.roundedBorder)
				.autocorrectionDisabled()
				.disabled(!store.hexSettings.remoteDictationEnabled)
				if store.hexSettings.remoteDictationEnabled {
					if !addressIsUsable {
						Text("Enter the server's http(s) or ws(s) address to turn this on.")
					} else if !store.hexSettings.superFastModeEnabled {
						Text("Needs Super Fast Mode, which provides the live audio.")
					}
				}
			} icon: {
				Image(systemName: "network")
			}
		}
		.enableInjection()
	}
}

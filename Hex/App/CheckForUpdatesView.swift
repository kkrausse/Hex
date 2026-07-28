import Combine
import ComposableArchitecture
import Inject
import Sparkle
import SwiftUI

@Observable
@MainActor
final class CheckForUpdatesViewModel {
	init() {
		anyCancellable = controller.updater.publisher(for: \.canCheckForUpdates)
			.sink(receiveValue: { self.canCheckForUpdates = $0 })
	}

	static let shared = CheckForUpdatesViewModel()

	// Fork: the updater is deliberately never started. This build has no Sparkle
	// feed (see Info.plist), and starting the updater without one makes Sparkle
	// throw SUNoFeedURLError and surface an alert on every launch. With
	// startingUpdater: false, `canCheckForUpdates` stays false and the menu item
	// below stays disabled. Flip this back only alongside a real appcast.
	let controller = SPUStandardUpdaterController(
		startingUpdater: false,
		updaterDelegate: nil,
		userDriverDelegate: nil
	)

	var anyCancellable: AnyCancellable?

	var canCheckForUpdates = false

	func checkForUpdates() {
		controller.updater.checkForUpdates()
	}
}

struct CheckForUpdatesView: View {
	@State var viewModel = CheckForUpdatesViewModel.shared
	@ObserveInjection var inject

	var body: some View {
		Button("Check for Updates…", action: viewModel.checkForUpdates)
			.disabled(!viewModel.canCheckForUpdates)
			.enableInjection()
	}
}

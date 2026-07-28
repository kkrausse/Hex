import Combine
import ComposableArchitecture
import Inject
import SwiftUI

#if canImport(Sparkle)
import Sparkle

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
	// stays disabled. Flip this back only alongside a real appcast.
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

#else

/// Stand-in used by the SPM executable build, where Sparkle is not linked.
///
/// Sparkle needs a real app bundle for its XPC installer service, and a bare
/// SPM executable has none. Since this fork disables auto-update regardless,
/// the SPM build simply drops the dependency and keeps the same surface so the
/// call sites in `HexApp` and `AboutView` compile unchanged.
@Observable
@MainActor
final class CheckForUpdatesViewModel {
	static let shared = CheckForUpdatesViewModel()

	/// Always false, so every "Check for Updates" affordance renders disabled.
	var canCheckForUpdates = false

	func checkForUpdates() {}
}

#endif

struct CheckForUpdatesView: View {
	@State var viewModel = CheckForUpdatesViewModel.shared
	@ObserveInjection var inject

	var body: some View {
		Button("Check for Updates…", action: viewModel.checkForUpdates)
			.disabled(!viewModel.canCheckForUpdates)
			.enableInjection()
	}
}

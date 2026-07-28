import Foundation

extension Bundle {
	/// The bundle holding Hex's own resources (`models.json`, `languages.json`,
	/// `changelog.md`, the sound effects).
	///
	/// The two build systems put them in different places. The Xcode app target
	/// copies them into the app bundle, so they resolve off `Bundle.main`. The SPM
	/// executable build declares them as target resources, so SwiftPM generates a
	/// separate `Hex_HexApp.bundle` reachable only through `Bundle.module` — and
	/// `Bundle.module` does not exist as a symbol in the Xcode build, so the
	/// reference itself has to be conditional, not just the value.
	static var hexResources: Bundle {
		#if SPM_BUILD
		return .module
		#else
		return .main
		#endif
	}
}

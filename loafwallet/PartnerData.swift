import Foundation
import UIKit

enum PartnerName {
	case unstop
	case infura
}

struct Partner {
	let logo: UIImage
	let headerTitle: String
	let details: String

	/// Fills partner data
	/// - Returns: Array of Partner Data
	static func partnerDataArray() -> [Partner] {
		let bitrefill = Partner(logo: UIImage(named: "bitrefillLogo")!, headerTitle: S.BuyCenter.Cells.bitrefillTitle.localize(), details: S.BuyCenter.Cells.bitrefillFinancialDetails.localize())
		let moonpay = Partner(logo: UIImage(named: "moonpay-logo")!, headerTitle: S.BuyCenter.Cells.moonpayTitle.localize(), details: S.BuyCenter.Cells.moonpayFinancialDetails.localize())
		let simplex = Partner(logo: UIImage(named: "simplexLogo")!, headerTitle: S.BuyCenter.Cells.simplexTitle.localize(), details: S.BuyCenter.Cells.simplexFinancialDetails.localize())

		return [bitrefill, moonpay, simplex]
	}

	/// Returns Partner Key
	/// - Parameter name: Enum for the different partners
	/// - Returns: Key string
	static func partnerKeyPath(name: PartnerName) -> String {
		/// Switch the config file based on the environment
		var filePath: String
		#if Release

			// Loads the release Partner Keys config file.
			guard let releasePath = Bundle.main.path(forResource: "partner-keys",
			                                         ofType: "plist")
			else {
				return "ERROR: FILE-NOT-FOUND"
			}
			filePath = releasePath
		#else

			// Loads the debug Partner Keys config file.
			guard let debugPath = Bundle.main.path(forResource: "debug-partner-keys",
			                                       ofType: "plist")
			else {
				return "ERROR: FILE-NOT-FOUND"
			}

			filePath = debugPath

		#endif

		switch name {
		case .infura:

			if let dictionary = NSDictionary(contentsOfFile: filePath) as? [String: AnyObject],
			   let key = dictionary["infura-api"] as? String
			{
				return "https://mainnet.infura.io/v3/" + key
			} else {
				let errorDescription = "ERROR-INFURA_KEY"
				LWAnalytics.logEventWithParameters(itemName: ._20200112_ERR, properties: ["error": errorDescription])
				return errorDescription
			}

		case .unstop:

			if let dictionary = NSDictionary(contentsOfFile: filePath) as? [String: AnyObject],
			   let key = dictionary["change-now-api"] as? String
			{
				return key
			} else {
				let errorDescription = "ERROR-CHANGENOW_KEY"
				LWAnalytics.logEventWithParameters(itemName: ._20200112_ERR, properties: ["error": errorDescription])
				return errorDescription
			}
		}
	}
}

import BRCore
import Foundation
import UIKit

enum SendResult {
	case success
	case creationError(String)
	case publishFailure(Error)
}

class Sender {
	// MARK: - Private Variables

	private let walletManager: WalletManager

	private let kvStore: BRReplicatedKVStore

	private let store: Store

	// MARK: - Public Variables

	var transaction: LndTransaction?

	var rate: Rate?

	var comment: String?

	var feePerKb: UInt64?

	var fee: UInt64 {
		guard let tx = transaction else { return 0 }
		return walletManager.wallet?.feeForTx(tx) ?? 0
	}

	var canUseBiometrics: Bool {
		guard let tx = transaction else { return false }
		return walletManager.canUseBiometrics(forTx: tx)
	}

	init(walletManager: WalletManager, kvStore: BRReplicatedKVStore, store: Store) {
		self.walletManager = walletManager
		self.kvStore = kvStore
		self.store = store
	}

	func createTransaction(amount: UInt64, to: String) -> Bool {
		transaction = walletManager.wallet?.createTransaction(forAmount: amount, toAddress: to)
		return transaction != nil
	}

	func feeForTx(amount: UInt64) -> UInt64 {
		return walletManager.wallet?.feeForTx(amount: amount) ?? 0
	}

	/// Send
	/// - Parameters:
	///   - biometricsMessage: Response from decoding the biometrics
	///   - rate: LTC - Fiat rate
	///   - comment: Users note to themselves
	///   - feePerKb: comment rate  of fee per kb
	///   - verifyPinFunction: verification
	///   - completion: completion
	func send(biometricsMessage: String,
	          rate: Rate?,
	          comment: String?,
	          feePerKb: UInt64,
	          verifyPinFunction:
	          @escaping (@escaping (String) -> Bool) -> Void,
	          completion: @escaping (SendResult) -> Void)
	{
		guard let tx = transaction
		else {
			return completion(.creationError(S.Send.createTransactionError.localize()))
		}

		self.rate = rate
		self.comment = comment
		self.feePerKb = feePerKb

		if UserDefaults.isBiometricsEnabled &&
			walletManager.canUseBiometrics(forTx: tx)
		{
			DispatchQueue.walletQueue.async { [weak self] in
				guard let myself = self else { return }
				myself
					.walletManager
					.signTransaction(tx,
					                 biometricsPrompt:
					                 biometricsMessage,
					                 completion: { result in
					                 	if result == .success {
					                 		myself.publish(completion: completion)
					                 	} else {
					                 		if result == .failure || result == .fallback {
					                 			myself.verifyPin(tx: tx,
					                 			                 withFunction: verifyPinFunction,
					                 			                 completion: completion)
					                 		}
					                 	}
					                 })
			}
		} else {
			verifyPin(tx: tx, withFunction: verifyPinFunction, completion: completion)
		}
	}

	func sendToCard(amount: UInt64, toAddress: String, completion: @escaping (Bool) -> Void) {
		if createTransaction(amount: amount, to: toAddress) {
			if let tx = transaction {
				DispatchQueue.walletQueue.async { [weak self] in
					guard let myself = self else { return }
					myself.walletManager.signCardTransaction(tx) { result in
						switch result {
						case .success:

							self?.publish(completion: { result in
								print("XXX \(result)")
							})

							completion(true)

						case .failure:
							print("XXX Failure")

						case .fallback:
							print("XXX Fallback")

						case .cancel:
							print("XXX Cancel")
						}
					}
				}
			}
		}
	}

	/// Verify Pin
	/// - Parameters:
	///   - tx: TX package
	///   - withFunction: completion mid-range
	///   - completion: completion

	// DEV: Important Note
	// This func needs to be REFACTORED as it violates OOP and intertangles TX and Pin authentication
	// This means it should be 2 functions.
	// VerifyPIN and VerifyTX
	private func verifyPin(tx: LndTransaction,
	                       withFunction: (@escaping (String) -> Bool) -> Void,
	                       completion: @escaping (SendResult) -> Void)
	{
		withFunction { pin in
			var success = false
			let group = DispatchGroup()
			group.enter()
			DispatchQueue.walletQueue.async {
				if self.walletManager.signTransaction(tx, pin: pin) {
					self.publish(completion: completion)
					success = true
				}
				group.leave()
			}
			let result = group.wait(timeout: .now() + 30.0)
			if result == .timedOut {
				let properties: [String: String] =
					["ERROR_TX": "\(tx.txHash)",
					 "ERROR_BLOCKHEIGHT": "\(tx.blockHeight)"]

				LWAnalytics.logEventWithParameters(itemName:
					._20200112_ERR,
					properties: properties)

				let alert = UIAlertController(title: S.LitewalletAlert.corruptionError.localize(),
				                              message: S.LitewalletAlert.corruptionMessage.localize(),
				                              preferredStyle: .alert)

				UserDefaults.didSeeCorruption = true
				alert.addAction(UIAlertAction(title: "OK",
				                              style: .default,
				                              handler: nil))
				return false
			}
			return success
		}
	}

	/// Publish TX
	/// - Parameter completion: completion
	private func publish(completion: @escaping (SendResult) -> Void) {
		guard let tx = transaction else { assertionFailure("publish failure"); return }
		DispatchQueue.walletQueue.async { [weak self] in
			guard let myself = self else { assertionFailure("myself didn't exist"); return }
			waitForAsync {
				do {
					try await myself.walletManager.lnd.publishTransaction(transaction: tx)
					DispatchQueue.main.async {
						myself.setMetaData()
						completion(.success)
					}
				} catch {
					DispatchQueue.main.async {
						completion(.publishFailure(error))
					}
				}
			}
		}
	}

	/// Set transaction metadata
	private func setMetaData() {
		// Fires an event if the rate is not set
		guard let rate = rate
		else {
			LWAnalytics.logEventWithParameters(itemName: ._20200111_RNI)
			return
		}

		// Fires an event if the transaction is not set
		guard let tx = transaction
		else {
			LWAnalytics.logEventWithParameters(itemName: ._20200111_TNI)
			return
		}

		// Fires an event if the feePerKb is not set
		guard let feePerKb = feePerKb
		else {
			LWAnalytics.logEventWithParameters(itemName: ._20200111_FNI)
			return
		}

		let metaData = TxMetaData(transaction: tx.pointee,
		                          exchangeRate: rate.rate,
		                          exchangeRateCurrency: rate.code,
		                          feeRate: Double(feePerKb),
		                          deviceId: UserDefaults.standard.deviceID,
		                          comment: comment)
		do {
			_ = try kvStore.set(metaData)
		} catch {
			LWAnalytics.logEventWithParameters(itemName: ._20200112_ERR,
			                                   properties: ["error":
			                                   	String(describing: error)])
		}
		store.trigger(name: .txMemoUpdated(tx.pointee.txHash.description))
	}
}

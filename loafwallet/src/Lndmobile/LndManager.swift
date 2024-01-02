import Foundation
import Lndmobile

enum LndError: Error {
	case notStarted
	case alreadyStarted
	case publishError(String)
}

class LndManager {
	private let testnet: Bool
	private let startArgs: [String]
	private var walletState: AsyncThrowingStream<Lnrpc_WalletState, Error>? = .none
	private(set) var walletExists = false
	private(set) var isStarted = false

	private var lndPath: String {
		let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		return applicationSupport.appendingPathComponent("lnd", isDirectory: true).path
	}

	init(testnet: Bool = false, args: [String] = []) {
		self.testnet = testnet
		startArgs = args
	}

	func start() async throws {
		guard !isStarted else { throw LndError.alreadyStarted }
		var lndArgs = ["--nolisten",
		               "--lnddir=\"\(lndPath)\"",
		               "--litecoin.active",
		               "--litecoin.node=neutrino",
		               "--no-macaroons"] + startArgs
		if testnet {
			lndArgs += ["--litecoin.testnet"]
		} else {
			lndArgs += ["--litecoin.mainnet"]
		}
		if E.isDebug {
			if testnet {
				lndArgs += ["--neutrino.addpeer=127.0.0.1:19335"]
			} else {
				lndArgs += ["--neutrino.addpeer=127.0.0.1:9333"]
			}
		}
		_ = try await withCheckedThrowingContinuation { cont in
			LndmobileStart(lndArgs.joined(separator: " "), LndmobileCallback(cont))
		}
		let req = Lnrpc_SubscribeStateRequest()
		walletState = AsyncThrowingStream { cont in
			LndmobileSubscribeState(try! req.serializedData(), LndmobileReceiveStream { result in
				switch result {
				case let .success(data):
					let resp = try! Lnrpc_SubscribeStateResponse(serializedData: data)
					cont.yield(resp.state)
				case let .failure(error):
					cont.finish(throwing: error)
				}
			})
		}
		for try await state in walletState! {
			if state == .nonExisting || state == .locked {
				walletExists = state == .locked
				break
			}
		}
		isStarted = true
	}

	func stop() async throws {
		guard isStarted else { throw LndError.notStarted }
		isStarted = false
		let req = Lnrpc_StopRequest()
		_ = try await withCheckedThrowingContinuation { cont in
			LndmobileStopDaemon(try! req.serializedData(), LndmobileCallback(cont))
		}
	}

	func deleteWallet() {
		let path = lndPath + "/data/chain/litecoin/\(testnet ? "testnet" : "mainnet")"
		try? FileManager.default.removeItem(atPath: path + "/wallet.db")
		try? FileManager.default.removeItem(atPath: path + "/channel.backup")
		walletExists = false
	}

	func initWallet(password: String, xprv: String, creationTime: TimeInterval, recoveryWindow: Int32 = 0) async throws {
		guard isStarted else { throw LndError.notStarted }
		var req = Lnrpc_InitWalletRequest()
		req.walletPassword = password.data(using: .utf8).unsafelyUnwrapped
		req.extendedMasterKey = xprv
		req.extendedMasterKeyBirthdayTimestamp = UInt64(creationTime)
		req.recoveryWindow = recoveryWindow
		_ = try await withCheckedThrowingContinuation { cont in
			LndmobileInitWallet(try! req.serializedData(), LndmobileCallback(cont))
		}
		for try await state in walletState! {
			if state == .serverActive {
				break
			}
		}
		subscribeBlocks()
		subscribeTransactions()
		walletExists = true
	}

	func unlockWallet(password: String, recoveryWindow: Int32 = 0) async throws {
		guard isStarted else { throw LndError.notStarted }
		var req = Lnrpc_UnlockWalletRequest()
		req.walletPassword = password.data(using: .utf8).unsafelyUnwrapped
		req.recoveryWindow = recoveryWindow
		_ = try await withCheckedThrowingContinuation { cont in
			LndmobileUnlockWallet(try! req.serializedData(), LndmobileCallback(cont))
		}
		for try await state in walletState! {
			if state == .serverActive {
				break
			}
		}
		subscribeBlocks()
		subscribeTransactions()
	}

	func getRecoveryInfo() async throws -> Double? {
		guard isStarted else { throw LndError.notStarted }
		let req = Lnrpc_GetRecoveryInfoRequest()
		let data = try await withCheckedThrowingContinuation { cont in
			LndmobileGetRecoveryInfo(try! req.serializedData(), LndmobileCallback(cont))
		}
		let resp = try Lnrpc_GetRecoveryInfoResponse(serializedData: data)
		if !resp.recoveryMode || resp.recoveryFinished { return nil }
		return resp.progress
	}

	private func subscribeBlocks() {
		let req = Chainrpc_BlockEpoch()
		LndmobileChainNotifierRegisterBlockEpochNtfn(try! req.serializedData(), LndmobileReceiveStream { result in
			switch result {
			case let .success(data):
				let _ = try! Chainrpc_BlockEpoch(serializedData: data)
				DispatchQueue.main.async {
					NotificationCenter.default.post(name: .walletBlockNotification, object: nil)
				}
			case .failure:
				break
			}
		})
	}

	private func subscribeTransactions() {
		let req = Lnrpc_GetTransactionsRequest()
		LndmobileSubscribeTransactions(try! req.serializedData(), LndmobileReceiveStream { result in
			switch result {
			case let .success(data):
				let transaction = LndTransaction(try! Lnrpc_Transaction(serializedData: data))
				DispatchQueue.main.async {
					NotificationCenter.default.post(name: .walletTxNotification, object: nil,
					                                userInfo: ["transaction": transaction])
				}
				if transaction.confirms < 6 {
					// self.subscribeConfirmations(transaction: transaction, confirms: transaction.confirms + 1, heightHint: transaction.blockHeight)
				}
			case .failure:
				break
			}
		})
	}

	private func subscribeConfirmations(transaction: LndTransaction, confirms: UInt32, heightHint: UInt32) {
		var req = Chainrpc_ConfRequest()
		req.txid = transaction.txHash.hexToData!
		req.numConfs = confirms
		req.heightHint = heightHint
		LndmobileChainNotifierRegisterConfirmationsNtfn(try! req.serializedData(), LndmobileReceiveStream { result in
			switch result {
			case let .success(data):
				let event = try! Chainrpc_ConfEvent(serializedData: data)
				switch event.event! {
				case let .conf(conf):
					transaction.blockHeight = conf.blockHeight
					transaction.confirms = confirms
					transaction.raw = conf.rawTx
					DispatchQueue.main.async {
						NotificationCenter.default.post(name: .walletTxStatusUpdateNotification, object: nil,
						                                userInfo: ["transaction": transaction])
					}
					if confirms < 6 {
						self.subscribeConfirmations(transaction: transaction, confirms: confirms + 1, heightHint: conf.blockHeight)
					}
				case .reorg:
					DispatchQueue.lndQueue.async {
						waitForAsync {
							try? await self.publishTransaction(transaction: transaction)
						}
					}
				}
			case .failure:
				break
			}
		})
	}

	func getTransactions() async throws -> [LndTransaction] {
		guard isStarted else { throw LndError.notStarted }
		let req = Lnrpc_GetTransactionsRequest()
		let data = try await withCheckedThrowingContinuation { cont in
			LndmobileGetTransactions(try! req.serializedData(), LndmobileCallback(cont))
		}
		let resp = try Lnrpc_TransactionDetails(serializedData: data)
		let transactions = resp.transactions.map { transaction in LndTransaction(transaction) }
			.sorted { txn1, txn2 in txn1.timestamp < txn2.timestamp }
		var balance: Int64 = 0
		for transaction in transactions {
			balance += transaction.amount
			transaction.balanceAfter = UInt64(balance)
		}
		return transactions
	}

	struct GetInfo {
		var numPeers: UInt32
		var blockHeight: UInt32
		var blockHash: String
		var bestHeaderTimestamp: TimeInterval
		var synced: Bool
	}

	func getInfo() async throws -> GetInfo {
		guard isStarted else { throw LndError.notStarted }
		let req = Lnrpc_GetInfoRequest()
		let data = try await withCheckedThrowingContinuation { cont in
			LndmobileGetInfo(try! req.serializedData(), LndmobileCallback(cont))
		}
		let resp = try Lnrpc_GetInfoResponse(serializedData: data)
		return GetInfo(numPeers: resp.numPeers,
		               blockHeight: resp.blockHeight,
		               blockHash: resp.blockHash,
		               bestHeaderTimestamp: TimeInterval(resp.bestHeaderTimestamp),
		               synced: resp.syncedToChain)
	}

	func getBalance() async throws -> UInt64 {
		guard isStarted else { throw LndError.notStarted }
		let req = Lnrpc_WalletBalanceRequest()
		let data = try await withCheckedThrowingContinuation { cont in
			LndmobileWalletBalance(try! req.serializedData(), LndmobileCallback(cont))
		}
		let resp = try Lnrpc_WalletBalanceResponse(serializedData: data)
		return UInt64(resp.totalBalance)
	}

	func getUnusedAddress() async throws -> String {
		guard isStarted else { throw LndError.notStarted }
		var req = Lnrpc_NewAddressRequest()
		req.type = .unusedWitnessPubkeyHash
		let data = try await withCheckedThrowingContinuation { cont in
			LndmobileNewAddress(try! req.serializedData(), LndmobileCallback(cont))
		}
		let resp = try Lnrpc_NewAddressResponse(serializedData: data)
		return resp.address
	}

	func estimateFee() async throws -> UInt64 {
		guard isStarted else { throw LndError.notStarted }
		var req = Walletrpc_EstimateFeeRequest()
		req.confTarget = 2
		let data = try await withCheckedThrowingContinuation { cont in
			LndmobileWalletKitEstimateFee(try! req.serializedData(), LndmobileCallback(cont))
		}
		let resp = try Walletrpc_EstimateFeeResponse(serializedData: data)
		return UInt64(resp.satPerKw)
	}

	func estimateFeeForAmount(address: String, amount: UInt64) async throws -> UInt64 {
		guard isStarted else { throw LndError.notStarted }
		var req = Lnrpc_EstimateFeeRequest()
		req.addrToAmount[address] = Int64(amount)
		req.targetConf = 2
		req.spendUnconfirmed = true
		let data = try await withCheckedThrowingContinuation { cont in
			LndmobileEstimateFee(try! req.serializedData(), LndmobileCallback(cont))
		}
		let resp = try Lnrpc_EstimateFeeResponse(serializedData: data)
		return UInt64(resp.feeSat)
	}

	func createTransaction(address: String, amount: UInt64, feeRate: UInt64) async throws -> LndTransaction {
		guard isStarted else { throw LndError.notStarted }
		var req = Walletrpc_FundPsbtRequest()
		req.raw = Walletrpc_TxTemplate()
		req.raw.outputs[address] = amount
		req.satPerVbyte = feeRate
		let data = try await withCheckedThrowingContinuation { cont in
			LndmobileWalletKitFundPsbt(try! req.serializedData(), LndmobileCallback(cont))
		}
		let resp = try Walletrpc_FundPsbtResponse(serializedData: data)
		let transaction = LndTransaction()
		transaction.psbt = resp.fundedPsbt
		return transaction
	}

	func createTransactionForOutputs(outputs: [LndTransaction.Output]) async throws -> LndTransaction {
		guard isStarted else { throw LndError.notStarted }
		var req = Walletrpc_SendOutputsRequest()
		req.outputs = outputs.map { output in
			var txo = Signrpc_TxOut()
			txo.value = Int64(output.amount)
			txo.pkScript = output.script
			return txo
		}
		let data = try await withCheckedThrowingContinuation { cont in
			LndmobileWalletKitSendOutputs(try! req.serializedData(), LndmobileCallback(cont))
		}
		let resp = try Walletrpc_SendOutputsResponse(serializedData: data)
		let transaction = LndTransaction()
		transaction.raw = resp.rawTx
		return transaction
	}

	func signTransaction(transaction: LndTransaction) async throws {
		guard isStarted else { throw LndError.notStarted }
		var req = Walletrpc_FinalizePsbtRequest()
		req.fundedPsbt = transaction.psbt!
		let data = try await withCheckedThrowingContinuation { cont in
			LndmobileWalletKitFinalizePsbt(try! req.serializedData(), LndmobileCallback(cont))
		}
		let resp = try Walletrpc_FinalizePsbtResponse(serializedData: data)
		transaction.raw = resp.rawFinalTx
	}

	func publishTransaction(transaction: LndTransaction) async throws {
		guard isStarted else { throw LndError.notStarted }
		var req = Walletrpc_Transaction()
		req.txHex = transaction.raw!
		let data = try await withCheckedThrowingContinuation { cont in
			LndmobileWalletKitPublishTransaction(try! req.serializedData(), LndmobileCallback(cont))
		}
		let resp = try Walletrpc_PublishResponse(serializedData: data)
		if resp.publishError != "" {
			throw LndError.publishError(resp.publishError)
		}
	}
}

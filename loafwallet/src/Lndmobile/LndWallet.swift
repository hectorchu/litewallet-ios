import Lndmobile

class LndWallet {
	private let lnd: LndManager

	init(lnd: LndManager) {
		self.lnd = lnd
	}

	// the first unused external address
	var receiveAddress: String {
		var address: String?
		waitForAsync {
			address = try? await self.lnd.getUnusedAddress()
		}
		return address ?? ""
	}

	// all previously generated internal and external addresses
	var allAddresses: [String] {
		return []
	}

	// true if the address is a previously generated internal or external address
	func containsAddress(_: String) -> Bool {
		return false
	}

	func addressIsUsed(_: String) -> Bool {
		return false
	}

	// transactions registered in the wallet, sorted by date, oldest first
	var transactions: [LndTransaction] {
		var transactions: [LndTransaction]?
		waitForAsync {
			transactions = try? await self.lnd.getTransactions()
		}
		return transactions ?? []
	}

	// current wallet balance, not including transactions known to be invalid
	var balance: UInt64 {
		var balance: UInt64?
		waitForAsync {
			balance = try? await self.lnd.getBalance()
		}
		return balance ?? 0
	}

	// total amount spent from the wallet (excluding change)
	var totalSent: UInt64 = 0

	// fee-per-kb of transaction size to use when creating a transaction
	var feePerKb: UInt64 {
		get {
			if feePerKw == nil {
				waitForAsync {
					self.feePerKw = try? await self.lnd.estimateFee()
				}
			}
			return (feePerKw ?? 0) / 4
		}
		set(fee) { feePerKw = fee * 4 }
	}

	private var feePerKw: UInt64?

	func feeForTx(amount: UInt64) -> UInt64 {
		let address = receiveAddress
		var fee: UInt64?
		waitForAsync {
			fee = try? await self.lnd.estimateFeeForAmount(address: address, amount: amount)
		}
		return fee ?? 0
	}

	// returns an unsigned transaction that sends the specified amount from the wallet to the given address
	func createTransaction(forAmount: UInt64, toAddress: String) -> LndTransaction? {
		var transaction: LndTransaction?
		let feeRate = feePerKb / 1000
		waitForAsync {
			transaction = try? await self.lnd.createTransaction(address: toAddress, amount: forAmount, feeRate: feeRate)
		}
		return transaction
	}

	// returns an unsigned transaction that satisifes the given transaction outputs
	func createTxForOutputs(_ outputs: [LndTransaction.Output]) -> LndTransaction? {
		var transaction: LndTransaction?
		waitForAsync {
			transaction = try? await self.lnd.createTransactionForOutputs(outputs: outputs)
		}
		return transaction
	}

	// signs any inputs in tx that can be signed using private keys from the wallet
	// returns true if all inputs were signed, or false if there was an error or not all inputs were able to be signed
	func signTransaction(_ transaction: LndTransaction) -> Bool {
		var ok: Void?
		waitForAsync {
			ok = try? await self.lnd.signTransaction(transaction: transaction)
		}
		return ok != nil
	}

	// true if no previous wallet transaction spends any of the given transaction's inputs, and no inputs are invalid
	func transactionIsValid(_: LndTransaction) -> Bool {
		return true
	}

	// true if transaction cannot be immediately spent (i.e. if it or an input tx can be replaced-by-fee)
	func transactionIsPending(_: LndTransaction) -> Bool {
		return false
	}

	// true if tx is considered 0-conf safe (valid and not pending, timestamp greater than 0, and no unverified inputs)
	func transactionIsVerified(_ transaction: LndTransaction) -> Bool {
		return transaction.timestamp > 0
	}

	// the amount received by the wallet from the transaction (total outputs to change and/or receive addresses)
	func amountReceivedFromTx(_ transaction: LndTransaction) -> UInt64 {
		return transaction.amount > 0 ? UInt64(transaction.amount) : 0
	}

	// the amount sent from the wallet by the transaction (total wallet outputs consumed, change and fee included)
	func amountSentByTx(_ transaction: LndTransaction) -> UInt64 {
		return transaction.amount < 0 ? UInt64(-transaction.amount) : 0
	}

	// returns the fee for the given transaction if all its inputs are from wallet transactions
	func feeForTx(_ transaction: LndTransaction) -> UInt64? {
		return transaction.fee
	}

	// historical wallet balance after the given transaction, or current balance if tx is not registered in wallet
	func balanceAfterTx(_ transaction: LndTransaction) -> UInt64 {
		return transaction.balanceAfter ?? 0
	}

	// fee that will be added for a transaction of the given size in bytes
	func feeForTxSize(_ vsize: Int) -> UInt64 {
		return UInt64(vsize) * feePerKb / 1000
	}

	// outputs below this amount are uneconomical due to fees (TX_MIN_OUTPUT_AMOUNT is the absolute min output amount)
	var minOutputAmount: UInt64 {
		return 1000
	}

	// maximum amount that can be sent from the wallet to a single address after fees
	var maxOutputAmount: UInt64 {
		let address = receiveAddress
		let amount = balance
		var fee: UInt64?
		waitForAsync {
			fee = try? await self.lnd.estimateFeeForAmount(address: address, amount: amount)
		}
		return amount - (fee ?? 0)
	}
}

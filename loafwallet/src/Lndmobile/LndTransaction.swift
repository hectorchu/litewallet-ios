import Foundation

open class LndTransaction {
	struct Input {
		var txHash: String
		var index: UInt32
	}

	struct Output {
		var address: String
		var amount: UInt64
		var script: Data
		var isOurs: Bool
	}

	var txHash = ""
	var amount: Int64 = 0
	var fee: UInt64 = 0
	var inputs: [Input] = []
	var outputs: [Output] = []
	var blockHeight: UInt32 = 0
	var confirms: UInt32 = 0
	var timestamp: TimeInterval = 0
	var balanceAfter: UInt64?
	var raw: Data?
	var psbt: Data?

	var pointee: LndTransaction { self }

	init() {}

	init(_ transaction: Lnrpc_Transaction) {
		txHash = transaction.txHash
		amount = transaction.amount
		fee = UInt64(transaction.totalFees)
		outputs = transaction.destAddresses.map { address in
			Output(address: address, amount: 0, script: Data(), isOurs: false)
		}
		blockHeight = UInt32(transaction.blockHeight)
		confirms = UInt32(transaction.numConfirmations)
		timestamp = TimeInterval(transaction.timeStamp)
		raw = transaction.rawTxHex.hexToData
	}
}

import Foundation

extension DispatchQueue {
	static let lndQueue: DispatchQueue = .init(label: C.lndQueue)

	static var walletQueue: DispatchQueue = .init(label: C.walletQueue)

	static let walletConcurrentQueue: DispatchQueue = .init(label: C.walletQueue, attributes: .concurrent)
}

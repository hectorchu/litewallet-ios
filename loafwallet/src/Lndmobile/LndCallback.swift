import Foundation
import Lndmobile

class LndmobileCallback: NSObject, LndmobileCallbackProtocol {
	var continuation: CheckedContinuation<Data, Error>

	init(_ continuation: CheckedContinuation<Data, Error>) {
		self.continuation = continuation
	}

	func onResponse(_ data: Data?) {
		switch data {
		case .none:
			continuation.resume(returning: Data())
		case let .some(data):
			continuation.resume(returning: data)
		}
	}

	func onError(_ error: Error?) {
		continuation.resume(throwing: error!)
	}
}

class LndmobileReceiveStream: NSObject, LndmobileRecvStreamProtocol {
	var callback: (Result<Data, Error>) -> Void

	init(_ callback: @escaping (Result<Data, Error>) -> Void) {
		self.callback = callback
	}

	func onResponse(_ data: Data?) {
		switch data {
		case .none:
			callback(.success(Data()))
		case let .some(data):
			callback(.success(data))
		}
	}

	func onError(_ error: Error?) {
		callback(.failure(error!))
	}
}

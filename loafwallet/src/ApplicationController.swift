import StoreKit
import UIKit

private let timeSinceLastExitKey = "TimeSinceLastExit"
private let shouldRequireLoginTimeoutKey = "ShouldRequireLoginTimeoutKey"
private let numberOfLitewalletLaunches = "NumberOfLitewalletLaunches"

class ApplicationController: Subscriber, Trackable {
	// Ideally the window would be private, but is unfortunately required
	// by the UIApplicationDelegate Protocol
	var window: UIWindow?
	fileprivate let store = Store()
	private var startFlowController: StartFlowPresenter?
	private var modalPresenter: ModalPresenter?

	fileprivate var walletManager: WalletManager?
	private var walletCoordinator: WalletCoordinator?
	private var exchangeUpdater: ExchangeUpdater?
	private var feeUpdater: FeeUpdater?
	private let transitionDelegate: ModalTransitionDelegate
	private var kvStoreCoordinator: KVStoreCoordinator?
	private var mainViewController: MainViewController?
	fileprivate var application: UIApplication?
	private var urlController: URLController?
	private var defaultsUpdater: UserDefaultsUpdater?
	private var reachability = ReachabilityMonitor()
	private let noAuthApiClient = BRAPIClient(authenticator: NoAuthAuthenticator())
	private var fetchCompletionHandler: ((UIBackgroundFetchResult) -> Void)?
	private var launchURL: URL?
	private var hasPerformedWalletDependentInitialization = false
	private var didInitWallet = false
	private let lnd = LndManager(testnet: E.isTestnet)

	init() {
		transitionDelegate = ModalTransitionDelegate(type: .transactionDetail, store: store)
		DispatchQueue.walletQueue.async {
			guardProtected(queue: DispatchQueue.walletQueue) {
				self.initWallet()
			}
		}
	}

	private func initWallet() {
		walletManager = try? WalletManager(store: store, lnd: lnd, dbPath: nil)
		_ = walletManager?.wallet // attempt to initialize wallet
		DispatchQueue.main.async {
			self.didInitWallet = true
			if !self.hasPerformedWalletDependentInitialization {
				self.didInitWalletManager()
			}
		}
	}

	func launch(application: UIApplication, window: UIWindow?) {
		self.application = application
		self.window = window
		application.setMinimumBackgroundFetchInterval(UIApplicationBackgroundFetchIntervalMinimum)
		setup()
		reachability.didChange = { isReachable in
			if !isReachable {
				self.reachability.didChange = { isReachable in
					if isReachable {
						self.retryAfterIsReachable()
					}
				}
			}
		}

		if !hasPerformedWalletDependentInitialization, didInitWallet {
			didInitWalletManager()
		}
	}

	private func setup() {
		setupDefaults()
		countLaunches()
		setupRootViewController()
		window?.makeKeyAndVisible()
		offMainInitialization()
		store.subscribe(self, name: .reinitWalletManager(nil), callback: {
			guard let trigger = $0 else { return }
			if case let .reinitWalletManager(callback) = trigger {
				if let callback = callback {
					NotificationCenter.default.post(name: .walletSyncStoppedNotification, object: nil)
					self.store.removeAllSubscriptions()
					self.store.perform(action: Reset())
					self.setup()
					DispatchQueue.walletQueue.async {
						do {
							self.walletManager = try WalletManager(store: self.store, lnd: self.lnd, dbPath: nil)
							_ = self.walletManager?.wallet // attempt to initialize wallet
						} catch {
							assertionFailure("Error creating new wallet: \(error)")
						}
						DispatchQueue.main.async {
							self.didInitWalletManager()
							callback()
						}
					}
				}
			}
		})

		TransactionManager.sharedInstance.fetchTransactionData(store: store)
	}

	func willEnterForeground() {
		guard let walletManager = walletManager else { return }
		guard !walletManager.noWallet else { return }
		if shouldRequireLogin() {
			store.perform(action: RequireLogin())
		}
		DispatchQueue.walletQueue.async {
			walletManager.peerManager?.connect()
		}
		exchangeUpdater?.refresh(completion: {})
		feeUpdater?.refresh()
		walletManager.apiClient?.kv?.syncAllKeys { print("KV finished syncing. err: \(String(describing: $0))") }
		walletManager.apiClient?.updateFeatureFlags()
		if modalPresenter?.walletManager == nil {
			modalPresenter?.walletManager = walletManager
		}
	}

	func retryAfterIsReachable() {
		guard let walletManager = walletManager else { return }
		guard !walletManager.noWallet else { return }
		DispatchQueue.walletQueue.async {
			walletManager.peerManager?.connect()
		}
		exchangeUpdater?.refresh(completion: {})
		feeUpdater?.refresh()
		walletManager.apiClient?.kv?.syncAllKeys { print("KV finished syncing. err: \(String(describing: $0))") }
		walletManager.apiClient?.updateFeatureFlags()
		if modalPresenter?.walletManager == nil {
			modalPresenter?.walletManager = walletManager
		}
	}

	func didEnterBackground() {
		if store.state.walletState.syncState == .success {
			DispatchQueue.walletQueue.async {
				self.walletManager?.peerManager?.disconnect()
			}
		}
		// Save the backgrounding time if the user is logged in
		if !store.state.isLoginRequired {
			UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timeSinceLastExitKey)
		}
		walletManager?.apiClient?.kv?.syncAllKeys { print("KV finished syncing. err: \(String(describing: $0))") }
	}

	func performFetch(_ completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
		fetchCompletionHandler = completionHandler
	}

	func open(url: URL) -> Bool {
		if let urlController = urlController {
			return urlController.handleUrl(url)
		} else {
			launchURL = url
			return false
		}
	}

	private func didInitWalletManager() {
		guard let walletManager = walletManager else { assertionFailure("WalletManager should exist!"); return }
		guard let rootViewController = window?.rootViewController else { return }

		hasPerformedWalletDependentInitialization = true
		store.perform(action: PinLength.set(walletManager.pinLength))
		walletCoordinator = WalletCoordinator(walletManager: walletManager, store: store)
		modalPresenter = ModalPresenter(store: store, walletManager: walletManager, window: window!, apiClient: noAuthApiClient)
		exchangeUpdater = ExchangeUpdater(store: store, walletManager: walletManager)
		feeUpdater = FeeUpdater(walletManager: walletManager, store: store)
		startFlowController = StartFlowPresenter(store: store, walletManager: walletManager, rootViewController: rootViewController)
		mainViewController?.walletManager = walletManager
		defaultsUpdater = UserDefaultsUpdater(walletManager: walletManager)
		urlController = URLController(store: store, walletManager: walletManager)
		if let url = launchURL {
			_ = urlController?.handleUrl(url)
			launchURL = nil
		}

		if UIApplication.shared.applicationState != .background {
			if walletManager.noWallet {
				UserDefaults.hasShownWelcome = true
				addWalletCreationListener()
				store.perform(action: ShowStartFlow())
			} else {
				modalPresenter?.walletManager = walletManager
				DispatchQueue.walletQueue.async {
					walletManager.peerManager?.connect()
				}
				startDataFetchers()
			}

			// For when watch app launches app in background
		} else {
			DispatchQueue.walletQueue.async { [weak self] in
				walletManager.peerManager?.connect()
				if self?.fetchCompletionHandler != nil {
					self?.performBackgroundFetch()
				}
			}
			exchangeUpdater?.refresh(completion: {
				// Update values
			})
		}
	}

	private func shouldRequireLogin() -> Bool {
		let then = UserDefaults.standard.double(forKey: timeSinceLastExitKey)
		let timeout = UserDefaults.standard.double(forKey: shouldRequireLoginTimeoutKey)
		let now = Date().timeIntervalSince1970
		return now - then > timeout
	}

	private func setupDefaults() {
		if UserDefaults.standard.object(forKey: shouldRequireLoginTimeoutKey) == nil {
			UserDefaults.standard.set(60.0 * 3.0, forKey: shouldRequireLoginTimeoutKey) // Default 3 min timeout
		}
	}

	private func countLaunches() {
		if var launchNumber = UserDefaults.standard.object(forKey: numberOfLitewalletLaunches) as? Int {
			launchNumber += 1
			UserDefaults.standard.set(NSNumber(value: launchNumber), forKey: numberOfLitewalletLaunches)
			if launchNumber == 5 {
				SKStoreReviewController.requestReview()
				LWAnalytics.logEventWithParameters(itemName: ._20200125_DSRR)
			}
		} else {
			UserDefaults.standard.set(NSNumber(value: 1), forKey: numberOfLitewalletLaunches)
		}
	}

	private func setupRootViewController() {
		mainViewController = MainViewController(store: store)
		window?.rootViewController = mainViewController
	}

	private func startDataFetchers() {
		walletManager?.apiClient?.updateFeatureFlags()
		initKVStoreCoordinator()
		feeUpdater?.refresh()
		defaultsUpdater?.refresh()
		walletManager?.apiClient?.events?.up()
		exchangeUpdater?.refresh(completion: {
			// Update values
		})
		initLnd()
	}

	private func initLnd() {
		DispatchQueue.lndQueue.async {
			waitForAsync {
				try? await self.lnd.start()
			}
			DispatchQueue.main.async {
				NotificationCenter.default.post(name: .walletSyncStartedNotification, object: nil)
			}
			DispatchQueue.walletQueue.async {
				waitForAsync {
					try? await self.walletManager?.initWallet()
				}
				DispatchQueue.main.async {
					NotificationCenter.default.post(name: .walletBalanceChangedNotification, object: nil)
				}
			}
		}
	}

	private func addWalletCreationListener() {
		store.subscribe(self, name: .didCreateOrRecoverWallet, callback: { _ in
			self.modalPresenter?.walletManager = self.walletManager
			self.startDataFetchers()
			self.mainViewController?.didUnlockLogin()
		})
	}

	private func initKVStoreCoordinator() {
		guard let kvStore = walletManager?.apiClient?.kv
		else {
			NSLog("kvStore not initialized")
			return
		}

		guard kvStoreCoordinator == nil
		else {
			NSLog("kvStoreCoordinator not initialized")
			return
		}

		kvStore.syncAllKeys { error in
			print("KV finished syncing. err: \(String(describing: error))")
			self.walletCoordinator?.kvStore = kvStore
			self.kvStoreCoordinator = KVStoreCoordinator(store: self.store, kvStore: kvStore)
			self.kvStoreCoordinator?.retreiveStoredWalletInfo()
			self.kvStoreCoordinator?.listenForWalletChanges()
		}
	}

	private func offMainInitialization() {
		DispatchQueue.global(qos: .background).async {
			_ = Rate.symbolMap // Initialize currency symbol map
		}
	}

	func performBackgroundFetch() {
		saveEvent("appController.performBackgroundFetch")
		let group = DispatchGroup()
		if let peerManager = walletManager?.peerManager, peerManager.syncProgress(fromStartHeight: peerManager.lastBlockHeight) < 1.0
		{
			group.enter()
			LWAnalytics.logEventWithParameters(itemName: ._20200111_DEDG)

			store.lazySubscribe(self, selector: { $0.walletState.syncState != $1.walletState.syncState }, callback: { state in
				if self.fetchCompletionHandler != nil {
					if state.walletState.syncState == .success {
						DispatchQueue.walletConcurrentQueue.async {
							peerManager.disconnect()
							self.saveEvent("appController.peerDisconnect")
							DispatchQueue.main.async {
								LWAnalytics.logEventWithParameters(itemName: ._20200111_DLDG)
								group.leave()
							}
						}
					}
				}
			})
		}

		group.enter()
		LWAnalytics.logEventWithParameters(itemName: ._20200111_DEDG)
		Async.parallel(callbacks: [
			{ self.exchangeUpdater?.refresh(completion: $0) },
			{ self.feeUpdater?.refresh(completion: $0) },
			{ self.walletManager?.apiClient?.events?.sync(completion: $0) },
			{ self.walletManager?.apiClient?.updateFeatureFlags(); $0() },
		], completion: {
			LWAnalytics.logEventWithParameters(itemName: ._20200111_DLDG)
			group.leave()
		})

		DispatchQueue.global(qos: .utility).async {
			if group.wait(timeout: .now() + 25.0) == .timedOut {
				self.saveEvent("appController.backgroundFetchFailed")
				self.fetchCompletionHandler?(.failed)
			} else {
				self.saveEvent("appController.backgroundFetchNewData")
				self.fetchCompletionHandler?(.newData)
			}
			self.fetchCompletionHandler = nil
		}
	}

	func willResignActive()
	{}
}

extension ApplicationController
{}

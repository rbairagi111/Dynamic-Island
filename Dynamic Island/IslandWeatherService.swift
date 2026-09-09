import CoreLocation
import Foundation
import Combine

struct IslandWeatherSnapshot: Equatable {
    var temperatureC: Int
    var weatherCode: Int
    var usAQI: Int?
    /// Open-Meteo `is_day` — drives Apple Weather day/night SF Symbols.
    var isDaytime: Bool

    var temperatureLabel: String { "\(temperatureC)°" }

    /// SF Symbol names aligned with WeatherKit / Apple Weather widget.
    var conditionSymbolName: String {
        switch weatherCode {
        case 0:
            return isDaytime ? "sun.max.fill" : "moon.stars.fill"
        case 1:
            return isDaytime ? "sun.max.fill" : "moon.stars.fill"
        case 2:
            return isDaytime ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3:
            return "cloud.fill"
        case 45, 48:
            return "cloud.fog.fill"
        case 51, 53, 55:
            return isDaytime ? "cloud.drizzle.fill" : "cloud.moon.rain.fill"
        case 56, 57:
            return "cloud.sleet.fill"
        case 61, 63, 80, 81:
            return "cloud.rain.fill"
        case 65, 82:
            return "cloud.heavyrain.fill"
        case 66, 67:
            return "cloud.sleet.fill"
        case 71, 73, 85:
            return "cloud.snow.fill"
        case 75, 77, 86:
            return "cloud.snow.fill"
        case 95:
            return "cloud.bolt.fill"
        case 96, 99:
            return "cloud.bolt.rain.fill"
        default:
            return isDaytime ? "cloud.sun.fill" : "cloud.moon.fill"
        }
    }

    /// Apple’s AQI SF Symbols (`aqi.low` / `.medium` / `.high`).
    var aqiSymbolName: String {
        guard let usAQI else { return "aqi.medium" }
        switch usAQI {
        case ...50: return "aqi.low"
        case 51...100: return "aqi.medium"
        default: return "aqi.high"
        }
    }

    var conditionLabel: String {
        switch weatherCode {
        case 0: return "Clear"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "Rain"
        case 71, 73, 75, 77, 85, 86: return "Snow"
        case 95, 96, 99: return "Thunderstorm"
        default: return "Cloudy"
        }
    }

    /// US AQI bands — nil when unavailable.
    var aqiLabel: String? {
        guard let usAQI else { return nil }
        return "AQI \(usAQI)"
    }

    var aqiCategory: String? {
        guard let usAQI else { return nil }
        switch usAQI {
        case ...50: return "Good"
        case 51...100: return "Moderate"
        case 101...150: return "Unhealthy for sensitive groups"
        case 151...200: return "Unhealthy"
        case 201...300: return "Very unhealthy"
        default: return "Hazardous"
        }
    }

    var aqiIsElevated: Bool {
        (usAQI ?? 0) >= 100
    }
}

/// Compact weather + US AQI via Open-Meteo (no API key). Location optional.
final class IslandWeatherService: NSObject, ObservableObject {
    static let shared = IslandWeatherService()

    @Published private(set) var snapshot: IslandWeatherSnapshot?
    @Published private(set) var authorizationDenied = false

    private let locationManager = CLLocationManager()
    private var refreshTimer: Timer?
    private var lastFetchAt: Date?
    private var lastCoordinate: CLLocationCoordinate2D?
    private let session: URLSession

    override init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        session = URLSession(configuration: config)
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.requestLocationAndFetch()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        requestLocationAndFetch()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func requestLocationAndFetch() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        case .denied, .restricted:
            authorizationDenied = true
            if let lastCoordinate {
                fetch(coordinate: lastCoordinate)
            }
        @unknown default:
            break
        }
    }

    private func fetch(coordinate: CLLocationCoordinate2D) {
        if let lastFetchAt, Date().timeIntervalSince(lastFetchAt) < 10 {
            return
        }
        lastFetchAt = Date()
        lastCoordinate = coordinate
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let weatherURL = URL(
            string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code,is_day"
        )!
        let aqiURL = URL(
            string: "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=\(lat)&longitude=\(lon)&current=us_aqi"
        )!

        let group = DispatchGroup()
        var temperature: Double?
        var code: Int?
        var isDay: Bool = true
        var aqi: Int?

        group.enter()
        session.dataTask(with: weatherURL) { data, _, _ in
            defer { group.leave() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any]
            else { return }
            temperature = current["temperature_2m"] as? Double
            code = current["weather_code"] as? Int
            if let day = current["is_day"] as? Int {
                isDay = day == 1
            } else if let day = current["is_day"] as? Double {
                isDay = day >= 1
            }
        }.resume()

        group.enter()
        session.dataTask(with: aqiURL) { data, _, _ in
            defer { group.leave() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any]
            else { return }
            if let value = current["us_aqi"] as? Int {
                aqi = value
            } else if let value = current["us_aqi"] as? Double {
                aqi = Int(value.rounded())
            }
        }.resume()

        group.notify(queue: .main) { [weak self] in
            guard let temperature else { return }
            self?.snapshot = IslandWeatherSnapshot(
                temperatureC: Int(temperature.rounded()),
                weatherCode: code ?? 3,
                usAQI: aqi,
                isDaytime: isDay
            )
        }
    }
}

extension IslandWeatherService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            authorizationDenied = false
            manager.requestLocation()
        case .denied, .restricted:
            authorizationDenied = true
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        fetch(coordinate: coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[IslandWeather] location failed: %@", error.localizedDescription)
    }
}

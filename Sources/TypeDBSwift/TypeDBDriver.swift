import CTypeDBDriver
import Foundation

/// Configuration options for connecting to TypeDB.
public struct TypeDBDriverOptions: Sendable {
    /// Whether TLS is enabled for the connection.
    public var tlsEnabled: Bool

    /// Path to the TLS root CA certificate file, if using custom CA.
    public var tlsRootCA: String?

    public init(tlsEnabled: Bool = false, tlsRootCA: String? = nil) {
        self.tlsEnabled = tlsEnabled
        self.tlsRootCA = tlsRootCA
    }
}

/// Credentials for authenticating with TypeDB.
public struct TypeDBCredentials: Sendable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// A connection to a TypeDB server.
///
/// Use `TypeDBDriver.connect` to establish a connection, then use the driver
/// to manage databases and create transactions.
///
/// ```swift
/// let driver = try TypeDBDriver.connect(to: "localhost:1729")
/// defer { driver.close() }
///
/// let databases = try driver.databases.all()
/// ```
public final class TypeDBDriver: @unchecked Sendable {
    private let lifetime: DriverLifetime
    private let managerLock = NSLock()
    private var databaseManager: DatabaseManager?
    private var userManager: UserManager?

    /// The database manager for this connection.
    public var databases: DatabaseManager {
        managerLock.withLock {
            if let databaseManager { return databaseManager }
            let manager = DatabaseManager(driver: self)
            databaseManager = manager
            return manager
        }
    }

    /// The user manager for this connection.
    public var users: UserManager {
        managerLock.withLock {
            if let userManager { return userManager }
            let manager = UserManager(driver: self)
            userManager = manager
            return manager
        }
    }

    private init(pointer: OpaquePointer) {
        self.lifetime = DriverLifetime(pointer: pointer)
    }

    deinit {
        close()
    }

    // MARK: - Connection

    /// Connect to a TypeDB server.
    ///
    /// - Parameters:
    ///   - address: The server address (e.g., "localhost:1729")
    ///   - credentials: Optional credentials for authentication (required for TypeDB Cloud)
    ///   - options: Connection options (TLS, etc.)
    /// - Returns: A connected TypeDBDriver instance
    /// - Throws: `TypeDBError` if the connection fails
    public static func connect(
        to address: String,
        credentials: TypeDBCredentials? = nil,
        options: TypeDBDriverOptions = TypeDBDriverOptions()
    ) throws -> TypeDBDriver {
        // Build the TLS configuration (TypeDB 3.11+ replaced the bool/root-CA
        // arguments to driver_options_new with an explicit DriverTlsConfig).
        let tlsConfig: OpaquePointer?
        if options.tlsEnabled {
            if let rootCA = options.tlsRootCA {
                tlsConfig = driver_tls_config_new_enabled_with_root_ca_path(rootCA)
            } else {
                tlsConfig = driver_tls_config_new_enabled_with_native_root_ca()
            }
        } else {
            tlsConfig = driver_tls_config_new_disabled()
        }
        guard let tlsConfigPtr = tlsConfig else {
            throw TypeDBError(code: "TLS_CONFIG_FAILED", message: "Failed to create TLS configuration")
        }

        // Create driver options (always required, non-null). driver_options_new
        // takes ownership of the TLS config pointer.
        guard let optionsPtr = driver_options_new(tlsConfigPtr) else {
            throw TypeDBError(code: "OPTIONS_FAILED", message: "Failed to create driver options")
        }
        defer { driver_options_drop(optionsPtr) }

        // Create credentials if provided
        // Note: For TypeDB Community without auth, we pass nil
        var credentialsPtr: OpaquePointer? = nil
        if let creds = credentials {
            credentialsPtr = credentials_new(creds.username, creds.password)
            if credentialsPtr == nil {
                throw TypeDBError(code: "CREDENTIALS_FAILED", message: "Failed to create credentials")
            }
        }
        defer {
            if let ptr = credentialsPtr {
                credentials_drop(ptr)
            }
        }

        // Open the connection. TypeDB 3.11+ renamed driver_open to driver_new
        // and added a driver_lang argument (NULL defaults to "c").
        guard let driverPtr = driver_new(address, credentialsPtr, optionsPtr, nil) else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(code: "CONNECTION_FAILED", message: "Failed to connect to \(address)")
        }

        try TypeDBError.checkAndThrow()
        return TypeDBDriver(pointer: driverPtr)
    }

    /// Check if the driver connection is still open.
    public var isOpen: Bool {
        (try? withOperation {
            guard let ptr = cPointer else { return false }
            return driver_is_open(ptr)
        }) ?? false
    }

    /// Close the driver connection.
    ///
    /// This method is idempotent and safe to call multiple times.
    public func close() {
        lifetime.close()
    }

    /// Force close the driver connection, aborting any pending operations.
    public func forceClose() {
        lifetime.close(force: true)
    }

    // MARK: - Internal

    /// Get the underlying C pointer for use by other wrapper types.
    internal var cPointer: OpaquePointer? {
        lifetime.borrowedPointer
    }

    internal func withOperation<T>(_ operation: () throws -> T) throws -> T {
        try lifetime.withLease(operation)
    }
}

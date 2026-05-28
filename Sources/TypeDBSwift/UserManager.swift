import CTypeDBDriver
import Foundation

/// Manages users on a TypeDB server.
public final class UserManager {
    private weak var driver: TypeDBDriver?

    internal init(driver: TypeDBDriver) {
        self.driver = driver
    }

    /// Get all users on the server.
    ///
    /// - Returns: An array of `User` instances
    /// - Throws: `TypeDBError` if the operation fails
    public func all() throws -> [User] {
        guard let driverPtr = driver?.cPointer else {
            throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
        }

        guard let iterator = users_all(driverPtr) else {
            try TypeDBError.checkAndThrow()
            return []
        }
        defer { user_iterator_drop(iterator) }

        var users: [User] = []
        while let userPtr = user_iterator_next(iterator) {
            users.append(User(pointer: userPtr))
        }

        try TypeDBError.checkAndThrow()
        return users
    }

    /// Check if a user with the given name exists.
    ///
    /// - Parameter username: The username to check
    /// - Returns: `true` if the user exists
    /// - Throws: `TypeDBError` if the operation fails
    public func contains(_ username: String) throws -> Bool {
        guard let driverPtr = driver?.cPointer else {
            throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
        }

        let result = users_contains(driverPtr, username)
        try TypeDBError.checkAndThrow()
        return result
    }

    /// Create a new user with the given username and password.
    ///
    /// - Parameters:
    ///   - username: The username for the new user
    ///   - password: The password for the new user
    /// - Throws: `TypeDBError` if the user cannot be created
    public func create(username: String, password: String) throws {
        guard let driverPtr = driver?.cPointer else {
            throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
        }

        users_create(driverPtr, username, password)
        try TypeDBError.checkAndThrow()
    }

    /// Get a user by username.
    ///
    /// - Parameter username: The username to look up
    /// - Returns: A `User` instance
    /// - Throws: `TypeDBError` if the user doesn't exist or operation fails
    public func get(_ username: String) throws -> User {
        guard let driverPtr = driver?.cPointer else {
            throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
        }

        guard let userPtr = users_get(driverPtr, username) else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(code: "USER_NOT_FOUND", message: "User '\(username)' not found")
        }

        try TypeDBError.checkAndThrow()
        return User(pointer: userPtr)
    }

    /// Get the current authenticated user.
    ///
    /// - Returns: The `User` that opened this connection
    /// - Throws: `TypeDBError` if the operation fails
    public func getCurrentUser() throws -> User {
        guard let driverPtr = driver?.cPointer else {
            throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
        }

        guard let userPtr = users_get_current(driverPtr) else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(code: "USER_NOT_FOUND", message: "Could not retrieve current user")
        }

        try TypeDBError.checkAndThrow()
        return User(pointer: userPtr)
    }

    /// Delete a user by username.
    ///
    /// - Parameter username: The username of the user to delete
    /// - Throws: `TypeDBError` if the deletion fails
    public func delete(username: String) throws {
        let user = try get(username)
        try user.delete()
    }
}

/// A TypeDB user.
public final class User {
    private var pointer: OpaquePointer?

    internal init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        if let ptr = pointer {
            user_drop(ptr)
        }
    }

    /// The name of this user.
    public var name: String {
        guard let ptr = pointer, let namePtr = user_get_name(ptr) else {
            return ""
        }
        let name = String(cString: namePtr)
        string_free(namePtr)
        return name
    }

    /// Update this user's password.
    ///
    /// - Parameter newPassword: The new password
    /// - Throws: `TypeDBError` if the update fails
    public func updatePassword(to newPassword: String) throws {
        guard let ptr = pointer else {
            throw TypeDBError(code: "USER_INVALID", message: "User reference is invalid")
        }

        user_update_password(ptr, newPassword)
        try TypeDBError.checkAndThrow()
    }

    /// Delete this user.
    ///
    /// - Throws: `TypeDBError` if the deletion fails
    public func delete() throws {
        guard let ptr = pointer else {
            throw TypeDBError(code: "USER_INVALID", message: "User reference is invalid")
        }

        // Guard: the C API aborts (SIGABRT) when deleting the default admin user
        // instead of setting an error flag. We check proactively to avoid a crash.
        let currentName = self.name
        if currentName == "admin" {
            throw TypeDBError(code: "USR3", message: "Default user cannot be deleted")
        }

        user_delete(ptr)
        try TypeDBError.checkAndThrow()
        pointer = nil
    }
}

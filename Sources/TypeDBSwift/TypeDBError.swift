import CTypeDBDriver
import Foundation

/// Errors that can occur when interacting with TypeDB.
public struct TypeDBError: Error, CustomStringConvertible {
    public let code: String
    public let message: String

    public var description: String {
        "[\(code)] \(message)"
    }

    init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// Check if an error occurred in the last C API call and throw if so.
    static func checkAndThrow() throws {
        if check_error() {
            guard let errorPtr = get_last_error() else {
                throw TypeDBError(code: "UNKNOWN", message: "Unknown error occurred")
            }
            defer { error_drop(errorPtr) }

            let code: String
            if let codePtr = error_code(errorPtr) {
                code = String(cString: codePtr)
                string_free(codePtr)
            } else {
                code = "UNKNOWN"
            }

            let message: String
            if let msgPtr = error_message(errorPtr) {
                message = String(cString: msgPtr)
                string_free(msgPtr)
            } else {
                message = "Unknown error"
            }

            throw TypeDBError(code: code, message: message)
        }
    }

    /// Check for error and return it without throwing, or nil if no error.
    static func getLastError() -> TypeDBError? {
        guard check_error(), let errorPtr = get_last_error() else {
            return nil
        }
        defer { error_drop(errorPtr) }

        let code: String
        if let codePtr = error_code(errorPtr) {
            code = String(cString: codePtr)
            string_free(codePtr)
        } else {
            code = "UNKNOWN"
        }

        let message: String
        if let msgPtr = error_message(errorPtr) {
            message = String(cString: msgPtr)
            string_free(msgPtr)
        } else {
            message = "Unknown error"
        }

        return TypeDBError(code: code, message: message)
    }
}

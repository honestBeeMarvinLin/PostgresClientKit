//
//  Connection.swift
//  PostgresClientKit
//
//  Copyright 2019 David Pitfield and the PostgresClientKit contributors
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import Socket
import SSLService

public class Connection: CustomStringConvertible {
    
    //
    // MARK: Connection lifecycle
    //
    
    /// Creates a connection.
    ///
    /// - Parameters:
    ///   - configuration: the connection configuration
    ///   - delegate: the optional delegate for the connection
    /// - Throws: `PostgresError` if the operation fails
    public init(configuration: ConnectionConfiguration,
                delegate: ConnectionDelegate? = nil) throws {
        
        var success = false
        
        self.delegate = delegate
        
        do {
            socket = try Socket.create()
            log(.finer, "Created socket")
        } catch {
            throw PostgresError.socketError(cause: error)
        }

        defer {
            if !success {
                log(.finer, "Closing socket")
                socket.close()
            }
        }
        
        let host = configuration.host
        let port = configuration.port

        do {
            log(.fine, "Opening connection to port \(port) on host \(host)")
            try socket.connect(to: host, port: Int32(port))
        } catch {
            throw PostgresError.socketError(cause: error)
        }
        
        if configuration.ssl {
            log(.finer, "Requesting SSL/TLS encryption")

            let sslRequest = SSLRequest()
            try sendRequest(sslRequest)
            let sslCode = try readASCIICharacter()
            
            guard sslCode == "S" else {
                throw PostgresError.sslNotSupported
            }
            
            let sslConfig = SSLService.Configuration()
            let sslService = try SSLService(usingConfiguration: sslConfig)!
            socket.delegate = sslService
            try sslService.initialize(asServer: false)
            try sslService.onConnect(socket: socket)
            
            log(.fine, "Successfully negotiated SSL/TLS encryption")
        }
        
        let user = configuration.user
        let database = configuration.database
        
        log(.fine, "Connecting to database \(database) as user \(user)")
        
        let startupRequest = StartupRequest(user: user, database: database)
        try sendRequest(startupRequest)
        
        authentication:
        while true {
            let authenticationResponse = try receiveResponse(type: AuthenticationResponse.self)
            
            switch authenticationResponse {
                
            case is AuthenticationOKResponse:
                break authentication
                
            case is AuthenticationCleartextPasswordResponse:
                
                guard case let .cleartextPassword(password) = configuration.credential else {
                    throw PostgresError.cleartextPasswordCredentialRequired
                }
                
                let passwordMessageRequest = PasswordMessageRequest(password: password)
                try sendRequest(passwordMessageRequest)
                
            case let response as AuthenticationMD5PasswordResponse:
                
                guard case let .md5Password(password) = configuration.credential else {
                    throw PostgresError.md5PasswordCredentialRequired
                }
                
                func md5AsHex(data: Data) -> String {
                    return Postgres.md5(data: data).map { String(format: "%02x", $0) }.joined()
                }
                
                // Compute concat('md5', md5(concat(md5(concat(password, username)), random-salt))).
                var passwordUser = password.data
                passwordUser.append(user.data)
                let passwordUserHash = md5AsHex(data: passwordUser)
                
                var salted = passwordUserHash.data
                salted.append(response.salt.data)
                let saltedHash = md5AsHex(data: salted)
                
                let passwordMessageRequest = PasswordMessageRequest(password: "md5" + saltedHash)
                try sendRequest(passwordMessageRequest)

            default:
                fatalError("\(authenticationResponse) not handled when connecting")
            }
        }
        
        try receiveResponse(type: ReadyForQueryResponse.self)
        
        log(.fine, "Successfully connected")
        success = true
    }
    
    /// An optional delegate for this connection.
    ///
    /// - Note: `Connection` holds a `weak` reference to the delegate.
    public weak var delegate: ConnectionDelegate?
    
    /// Uniquely identifies this connection.  Used in logging.
    private let id = "Connection-\(Postgres.nextId())"

    /// Whether this connection is closed.
    ///
    /// To close a connection, call `close()`.  A connection is also closed if an unrecoverable
    /// error occurs (for example, if the connection is closed by the Postgres server).
    public var isClosed: Bool {
        return !socket.isConnected
    }
    
    /// Closes this connection.
    ///
    /// Has not effect if this connection is already closed.
    public func close() {
        if !isClosed {
            log(.fine, "Closing connection")
            let terminateRequest = TerminateRequest()
            try? sendRequest(terminateRequest) // consumes any Error
            
            log(.finer, "Closing socket")
            socket.close()
            
            log(.fine, "Connection closed")
        }
    }
    
    /// Verifies this connection is not closed.
    ///
    /// - Throws: `PostgresError.connectionClosed` if closed
    private func verifyConnectionNotClosed() throws {
        if isClosed {
            throw PostgresError.connectionClosed
        }
    }
    
    deinit {
        close()
    }
    
    /// Attempts to resynchronize this collection, closing this connection if resynchronization
    /// fails.
    ///
    /// The Postgres server requires resynchronization to be performed after reporting an
    /// `ErrorResponse`.
    private func resyncOrCloseConnection() {
        if !isClosed {
            do {
                let syncRequest = SyncRequest()
                try sendRequest(syncRequest)
                try receiveResponse(type: ReadyForQueryResponse.self)
            } catch {
                log(.warning, "Closing connection due to unrecoverable error: \(error)")
                close()
            }
        }
    }
    

    //
    // MARK: Statement execution
    //
    
    
    /// Prepares a SQL statement for execution.
    ///
    /// Any previous `Result` instance for this connection is closed.
    ///
    /// - Parameter text: the SQL text
    /// - Returns: the prepared statement
    /// - Throws: `PostgresError` if the operation fails
    public func prepareStatement(text: String) throws -> Statement {
        
        let statement = Statement(connection: self, text: text)
        
        try performExtendedQueryOperation(
            operation: {
                let parseRequest = ParseRequest(statement: statement)
                try sendRequest(parseRequest)
                
                let flushRequest = FlushRequest()
                try sendRequest(flushRequest)
                
                try receiveResponse(type: ParseCompleteResponse.self)
            },
            onError: {
                // An error took place, but we don't know whether it occurred before or after the
                // Postgres server allocated resources for the statement.  Close the statement to
                // be safe.
                statement.close()
            }
        )
        
        return statement
    }
    
    /// Called by `Statement.execute(parameterValues:)` to execute a statement.
    ///
    /// Any previous `Result` instance for this connection is closed.
    ///
    /// - Parameters:
    ///   - statement: the statement
    ///   - parameterValues: the values of the bind parameters
    /// - Returns: the result
    /// - Throws: `PostgresError` is the operation fails
    internal func executeStatement(_ statement: Statement,
                                   parameterValues: [ValueConvertible?] = []) throws -> Result {
        
        try performExtendedQueryOperation(
            operation: {
                try verifyStatementNotClosed(statement)
                
                let bindRequest = BindRequest(statement: statement, parameterValues: parameterValues)
                try sendRequest(bindRequest)
                
                let flushRequest = FlushRequest()
                try sendRequest(flushRequest)
                
                try receiveResponse(type: BindCompleteResponse.self)
                
                let executeRequest = ExecuteRequest(statement: statement)
                try sendRequest(executeRequest)
                
                try sendRequest(flushRequest)
            },
            onError: {
                // No cleanup required.  Since we always execute statements in the "unnamed portal"
                // any resources allocated by the Postgres server will be released at the end of the
                // current transaction or upon the next `BindRequest`, whichever comes first.
            }
        )
            
        let result = Result(statement: statement)
        
        // (The ResultState enum cases capture the Result id, rather than the Result instance, to
        // avoid a reference cycle).
        resultState = .open(resultId: result.id, bufferedRow: nil)
        
        // Retrieve and buffer the first row of the result, if any.  We do this to check whether
        // the execution failed, so we can throw an error from this method.
        if let firstRow = try nextRowOfResult(result) {
            resultState = .open(resultId: result.id, bufferedRow: firstRow)
        }
        
        return result
    }
    
    /// Called by `Statement.close()` to close a statement.
    ///
    /// Any previous `Result` instance for this connection is closed.
    ///
    /// If an error occurs, it is logged but not thrown.
    ///
    /// - Parameter statement: the statement
    internal func closeStatement(_ statement: Statement) {
        
        do {
            try performExtendedQueryOperation(
                operation: {
                    if !statement.isClosed {
                        let closeStatementRequest = CloseStatementRequest(statement: statement)
                        try sendRequest(closeStatementRequest)
                        
                        let flushRequest = FlushRequest()
                        try sendRequest(flushRequest)
                        
                        try receiveResponse(type: CloseCompleteResponse.self)
                    }
                }
            )
        } catch {
            log(.warning, "Error closing \(statement): \(error)")
        }
    }
    
    /// Verifies the specified statement is not closed.
    ///
    /// - Throws: `PostgresError.statementClosed` if closed
    private func verifyStatementNotClosed(_ statement: Statement) throws {
        if statement.isClosed {
            throw PostgresError.statementClosed
        }
    }
    
    /// Enumerates the result states of a connection.
    ///
    /// Between when it is created and when it is closed, a connection can perform a sequence of
    /// SQL statements.  Each statement is performed by an exchange between PostgresClientKit and
    /// the Postgres server of "extended query" requests and responses.  For more information, see
    /// https://www.postgresql.org/docs/11/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY.
    ///
    /// A SQL statement can return a result consisting of a one or more rows.  Instead of exposing
    /// this result as an array of rows, PostgresClientKit exposes an iterator by which the next
    /// row can be obtained as needed.  This approach doesn't require materializing all rows in
    /// memory at once, and doesn't require retrieval of the last row from the Postgres server
    /// before returning the first row through the PostgresClientKit API.
    ///
    /// However, this approach makes `Connection` instances stateful, at least internally.  This
    /// enumeration identifies the possible states.  The `resultState` property records the current
    /// state of this connection.
    private enum ResultState {
        
        /// There is no currently open result.
        case closed
        
        /// There is a currently open result, with an optional buffered row.
        case open(resultId: String, bufferedRow: Row?)
        
        /// There is a currently open result, but all rows have been retrieved.
        case drained(resultId: String)
    }
    
    /// The current result state of this connection.
    private var resultState = ResultState.closed
    
    /// Called by the implementations of the public APIs that prepare a new statement, bind
    /// parameter values to and execute a previously prepared statement, and close a statement.
    ///
    /// This method provides a consistent pattern for performing these operations.  It:
    ///
    ///     - Transitions this connection to the `closed` `ResultState` (if not already in that
    ///       state)
    ///     - Verifies other preconditions for performing the operation
    ///     - Executes the operation
    ///     - Upon an error in any of the previous steps, attempts to resynchronize this connection
    ///       with the Postgres server then executes an optional error recovery closure
    ///
    /// - Parameters:
    ///   - operation: the operation to perform
    ///   - onError: an error recovery closure, executed if `operation` throws
    /// - Throws: `PostgresError` if the operation fails
    private func performExtendedQueryOperation(operation: () throws -> Void,
                                               onError: () -> Void = { }) throws {
        
        do {
            // If there is a currently open result, close it.  (If an unrecoverable error occurs,
            // this will close this connection.)
            closeCurrentlyOpenResult()
            
            guard case .closed = resultState else {
                preconditionFailure("resultState not closed after closeCurrentlyOpenResult()")
            }
            
            // Verify this connection is still open.
            try verifyConnectionNotClosed()
            
            // Perform the operation.
            try operation()
        } catch {
            // An error occurred, so try to resync this connection with the Postgres server.
            // If not successful, close this connection.
            resyncOrCloseConnection()
            
            // Perform the caller's error recovery closure (which should handle the case where
            // this connection is closed).
            onError()
            
            // And rethrow the original error.
            throw error
        }
    }
    

    //
    // MARK: Result processing
    //
    
    /// Returns the next row of the currently open result.
    ///
    /// - Parameter result: the `Result` instance for the currently open result, or nil if not
    ///     available
    /// - Returns: the next row, or nil if there are no more rows in the result
    /// - Throws: `PostgresError` if the operation fails
    internal func nextRowOfResult(_ result: Result? = nil) throws -> Row? {
        
        try verifyConnectionNotClosed()
        
        if let result = result {
            try verifyStatementNotClosed(result.statement)
            try verifyResultNotClosed(result) // verify that *this specific* result is open
        }
        
        var row: Row?
        
        switch resultState {
            
        case .closed:
            throw PostgresError.resultClosed // verify that *any* result is open
            
        case .drained:
            row = nil
            
        case let .open(resultId: resultId, bufferedRow: bufferedRow):
            
            do {
                // Do we have a row buffered?
                if let bufferedRow = bufferedRow {
                    
                    // Yes, so return it.
                    row = bufferedRow
                    resultState = .open(resultId: resultId, bufferedRow: nil)
                    
                } else {
                    
                    // No, so try to fetch a row from the Postgres server.
                    let response = try receiveResponse()
                    
                    switch response {
                        
                    case is EmptyQueryResponse: // the result has no rows
                        result?.rowCount = 0
                        resultState = .drained(resultId: resultId)
                        
                    case let commandCompleteResponse as CommandCompleteResponse: // no more rows
                        let tokens = commandCompleteResponse.commandTag.split(separator: " ")
                        
                        switch tokens[0] {
                            
                        case "INSERT":
                            result?.rowCount = Int(tokens[2])
                            
                        case "DELETE", "UPDATE", "SELECT", "MOVE", "FETCH", "COPY":
                            result?.rowCount = Int(tokens[1])
                            
                        default:
                            break
                        }
                        
                        resultState = .drained(resultId: resultId)

                    case let dataRowResponse as DataRowResponse:
                        row = Row(columns: dataRowResponse.columns)
                        
                    default:
                        throw PostgresError.serverError(
                            description: "unexpected response '\(response)'")
                    }
                }
                
                if case .drained = resultState {
                    
                    // We just transitioned from .open to .drained.  Close the portal to release
                    // Postgres server resources.  Then perform a SyncRequest to close (commit or
                    // rollback) the current transaction (unless within a BEGIN/COMMIT block).
                    
                    let closePortalRequest = ClosePortalRequest()
                    try sendRequest(closePortalRequest)
                    
                    let flushRequest = FlushRequest()
                    try sendRequest(flushRequest)
                    
                    try receiveResponse(type: CloseCompleteResponse.self)
                    
                    let syncRequest = SyncRequest()
                    try sendRequest(syncRequest)
                    
                    try receiveResponse(type: ReadyForQueryResponse.self)
                }
            } catch {
                // An error occurred, so try to resync this connection with the Postgres server.
                // If not successful, close this connection.
                resyncOrCloseConnection()
                
                // And rethrow that error.
                throw error
            }
        }
        
        return row
    }
    
    /// Gets whether the specified result is closed.
    ///
    /// - Parameter result: the result to test
    /// - Returns: whether closed
    internal func isResultClosed(_ result: Result) -> Bool {
        switch resultState {
            
        case .closed:
            return true
            
        case let .open(resultId: resultId, bufferedRow: _):
            return resultId != result.id
            
        case let .drained(resultId: resultId):
            return resultId != result.id
        }
    }
    
    /// Closes the specified result.
    ///
    /// - Parameter result: the result
    internal func closeResult(_ result: Result) {
        if !isResultClosed(result) {
            closeCurrentlyOpenResult()
        }
    }

    /// Closes any currently open result.
    private func closeCurrentlyOpenResult() {
        do {
            if !isClosed {
                if case .open = resultState {
                    while try nextRowOfResult() != nil { } // drain any remaining rows
                }
            }
            
            resultState = .closed
        } catch {
            log(.warning, "Error closing result: \(error)")
        }
    }
    
    /// Verifies the specified result is not closed.
    ///
    /// - Parameter result: the result
    /// - Throws: `PostgresError.resultClosed` if closed
    private func verifyResultNotClosed(_ result: Result) throws {
        if isResultClosed(result) {
            throw PostgresError.resultClosed
        }
    }
    

    //
    // MARK: Convenience methods
    //
    
    public func beginTransaction() throws {
        fatalError("FIXME: implement")
    }
    
    public func commitTransaction() throws {
        fatalError("FIXME: implement")
    }
    
    public func rollbackTransaction() throws {
        fatalError("FIXME: implement")
    }
    
    
    //
    // MARK: Request processing
    //
    
    private func sendRequest(_ request: Request) throws {
        
        log(.finer, "Sending \(request)")

        do {
            try socket.write(from: request.data())
        } catch {
            throw PostgresError.socketError(cause: error)
        }
    }
    
    
    //
    // MARK: Response processing
    //
    
    @discardableResult private func receiveResponse<T: Response>(type: T.Type? = nil) throws -> T {
        
        while true {
            
            let responseType = try readASCIICharacter()
            
            // The response length includes itself (4 bytes) but excludes the response type (1 byte).
            let responseLength = try readUInt32()
            
            let responseBody = ResponseBody(responseType: responseType,
                                            responseLength: Int(responseLength),
                                            connection: self)
            
            let response: Response
            
            switch responseType {
                
            case "1": response = try ParseCompleteResponse(responseBody: responseBody)
            case "2": response = try BindCompleteResponse(responseBody: responseBody)
            case "3": response = try CloseCompleteResponse(responseBody: responseBody)
            case "C": response = try CommandCompleteResponse(responseBody: responseBody)
            case "D": response = try DataRowResponse(responseBody: responseBody)
            case "E": response = try ErrorResponse(responseBody: responseBody)
            case "I": response = try EmptyQueryResponse(responseBody: responseBody)
            case "K": response = try BackendKeyDataResponse(responseBody: responseBody)
            case "N": response = try NoticeResponse(responseBody: responseBody)
            case "R": response = try AuthenticationResponse.parse(responseBody: responseBody)
            case "S": response = try ParameterStatusResponse(responseBody: responseBody)
            case "Z": response = try ReadyForQueryResponse(responseBody: responseBody)
                
            default:
                throw PostgresError.serverError(
                    description: "unrecognized response type '\(responseType)'")
            }
            
            log(.finer, "Received \(response)")
            
            switch response {
                
            case is BackendKeyDataResponse:
                break // don't need this, since we don't support CancelRequest
                
            case let errorResponse as ErrorResponse:
                throw PostgresError.sqlError(notice: errorResponse.notice)
                
            case let noticeResponse as NoticeResponse:
                delegate?.connection(self, didReceiveNotice: noticeResponse.notice)
                
            case let parameterStatusResponse as ParameterStatusResponse:
                
                delegate?.connection(
                    self,
                    didReceiveParameterStatus: (name: parameterStatusResponse.name,
                                                value: parameterStatusResponse.value))
                
                try Parameter.checkParameterStatusResponse(parameterStatusResponse)
                
            case is T:
                return response as! T
                
            default:
                throw PostgresError.serverError(description: "unexpected response type '\(responseType)'")
            }
        }
    }
    
    /// The body of a response (everything after the bytes indicating the response length).
    internal class ResponseBody {
        
        /// Creates an instance.
        ///
        /// - Parameters:
        ///   - responseType: the response type
        ///   - responseLength: the response length, in bytes
        ///   - connection: the connection
        fileprivate init(responseType: Character, responseLength: Int, connection: Connection) {
            
            self.responseType = responseType
            
            // responseLength includes the 4-byte response length
            self.bytesRemaining = responseLength - 4
            
            self.connection = connection
        }
        
        internal let responseType: Character
        private var bytesRemaining: Int
        private let connection: Connection
        
        /// Reads an unsigned 8-bit integer without consuming it.
        ///
        /// - Returns: the value
        /// - Throws: `PostgresError` if the operation fails
        internal func peekUInt8() throws -> UInt8 {
            
            if bytesRemaining == 0 {
                throw PostgresError.serverError(description: "response too short")
            }
            
            let byte = try connection.peekUInt8()
            
            return byte
        }
        
        /// Reads an unsigned 8-bit integer.
        ///
        /// - Returns: the value
        /// - Throws: `PostgresError` if the operation fails
        @discardableResult internal func readUInt8() throws -> UInt8 {
            
            if bytesRemaining == 0 {
                throw PostgresError.serverError(description: "response too short")
            }
            
            let byte = try connection.readUInt8()
            bytesRemaining -= 1
            
            return byte
        }
        
        /// Reads an unsigned 16-bit integer.
        ///
        /// - Returns: the value
        /// - Throws: `PostgresError` if the operation fails
        internal func readUInt16() throws -> UInt16 {
            
            let value = try
                UInt16(readUInt8()) << 8 +
                UInt16(readUInt8())
            
            return value
        }
        
        /// Reads an unsigned 32-bit integer.
        ///
        /// - Returns: the value
        /// - Throws: `PostgresError` if the operation fails
        internal func readUInt32() throws -> UInt32 {
            
            let value = try
                UInt32(readUInt8()) << 24 +
                UInt32(readUInt8()) << 16 +
                UInt32(readUInt8()) << 8 +
                UInt32(readUInt8())
            
            return value
        }

        /// Reads the specified number of bytes.
        ///
        /// - Parameter count: the number of bytes to read
        /// - Returns: the data
        /// - Throws: `PostgresError` if the operation fails
        internal func readData(count: Int) throws -> Data {
            
            if bytesRemaining < count {
                throw PostgresError.serverError(description: "response too short")
            }
            
            let data = try connection.readData(count: count)
            bytesRemaining -= data.count
            
            assert(data.count == count)
            
            return data
        }
        
        /// Reads a single ASCII character.
        ///
        /// - Returns: the character
        /// - Throws: `PostgresError` if the operation fails
        internal func readASCIICharacter() throws -> Character {
            
            let c = try Character(Unicode.Scalar(readUInt8()))
            
            return c
        }

        /// Reads a null-terminated UTF8 string.
        ///
        /// - Returns: the string
        /// - Throws: `PostgresError` if the operation fails
        internal func readUTF8String() throws -> String {
            
            var data = Data()
            
            while true {
                let b = try readUInt8()
                
                if b == 0 {
                    break
                }
                
                data.append(b)
            }
            
            guard let s = String(data: data, encoding: .utf8) else {
                throw PostgresError.serverError(description: "response contained invalid UTF8 string")
            }
            
            return s
        }
        
        /// Reads a UTF8 string.
        ///
        /// - Parameter byteCount: the length of the string, in bytes
        /// - Returns: the string
        /// - Throws: `PostgresError` if the operation fails
        @discardableResult internal func readUTF8String(byteCount: Int) throws -> String {
            
            let data = try readData(count: byteCount)
            
            guard let s = String(data: data, encoding: .utf8) else {
                throw PostgresError.serverError(description: "response contained invalid UTF8 string")
            }
            
            return s
        }
        
        /// Verifies the response body has been fully consumed.
        ///
        /// - Throws: `PostgresError` if not fully consumed
        internal func verifyFullyConsumed() throws {
            if bytesRemaining != 0 {
                throw PostgresError.serverError(description: "response too long")
            }
        }
    }
    
    
    //
    // MARK: Socket
    //
    
    /// The underlying socket to the Postgres server.
    private let socket: Socket
    
    /// A buffer of data read from Postgres but not yet consumed.
    private var readBuffer = Data()
    
    /// The index of the next byte to consume from the read buffer.
    private var readBufferPosition = 0
    
    /// Reads an unsigned 8-bit integer from Postgres without consuming it.
    ///
    /// - Returns: the value
    /// - Throws: `PostgresError` if the operation fails
    private func peekUInt8() throws -> UInt8 {
        
        if readBufferPosition == readBuffer.count {
            try refillReadBuffer()
        }
        
        let byte = readBuffer[readBufferPosition]
        
        return byte
    }
    
    /// Reads an unsigned 8-bit integer from Postgres.
    ///
    /// - Returns: the value
    /// - Throws: `PostgresError` if the operation fails
    private func readUInt8() throws -> UInt8 {
        
        let byte = try peekUInt8()
        readBufferPosition += 1
        
        return byte
    }
    
    /// Reads an unsigned big-endian 32-bit integer from Postgres.
    ///
    /// - Returns: the value
    /// - Throws: `PostgresError` if the operation fails
    private func readUInt32() throws -> UInt32 {
        
        let value = try
            UInt32(readUInt8()) << 24 +
            UInt32(readUInt8()) << 16 +
            UInt32(readUInt8()) << 8 +
            UInt32(readUInt8())
        
        return value
    }
    
    /// Reads the specified number of bytes from Postgres.
    ///
    /// - Parameter count: the number of bytes to read
    /// - Returns: the data
    /// - Throws: `PostgresError` if the operation fails
    private func readData(count: Int) throws -> Data {
        
        var data = Data()
        
        while data.count < count {
            
            let fromIndex = readBufferPosition
            let toIndex = min(readBufferPosition + count, readBuffer.count)
            let chunk = readBuffer[fromIndex..<toIndex]
            data += chunk
            readBufferPosition += chunk.count
            
            if data.count < count {
                try refillReadBuffer()
            }
        }
        
        assert(data.count == count)
        
        return data
    }
    
    /// Reads a single ASCII character from Postgres.
    ///
    /// - Returns: the character
    /// - Throws: `PostgresError` if the operation fails
    private func readASCIICharacter() throws -> Character {
        
        let c = try Character(Unicode.Scalar(readUInt8()))
        
        return c
    }
    
    private func refillReadBuffer() throws {
        
        assert(readBufferPosition == readBuffer.count)
        
        readBuffer.removeAll()
        readBufferPosition = 0
        
        var readCount = 0
        
        do {
            readCount = try socket.read(into: &readBuffer)
        } catch {
            throw PostgresError.socketError(cause: error)
        }
        
        if readCount == 0 {
            throw PostgresError.serverError(description: "no data available from server")
        }
    }
    
    
    //
    // MARK: Logging
    //
    
    private func log(_ level: LogLevel,
                    _ message: CustomStringConvertible,
                    file: String = #file,
                    function: String = #function,
                    line: Int = #line) {
        
        Postgres.logger.log(level: level,
                            message: message,
                            context: self,
                            file: file,
                            function: function,
                            line: line)
    }
    
    
    //
    // MARK: CustomStringConvertible
    //
    
    /// A short string that identifies this connection.
    public var description: String { return id }
}

// EOF
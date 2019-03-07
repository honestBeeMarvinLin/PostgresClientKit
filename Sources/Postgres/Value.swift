//
//  Value.swift
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

public struct Value: ValueConvertible, CustomStringConvertible {
    
    public init(_ rawValue: String?) { }
    
    public var postgresValue: Value {
        fatalError()
    }
    
    public var isNull: Bool {
        fatalError()
    }
    
    public func optionalInt() throws -> Int? {
        fatalError()
    }
    
    public func int() throws -> Int {
        fatalError()
    }
    
    public func optionalString() throws -> String? {
        fatalError()
    }
    
    public func string() throws -> String {
        fatalError()
    }
    
    public func optionalDate() throws -> Date? {
        fatalError()
    }
    
    public func date() throws -> Date {
        fatalError()
    }
    
    // ...similar conversions for other basic Swift types...
    
    public var description: String {
        return "FIXME"
    }
}

// EOF

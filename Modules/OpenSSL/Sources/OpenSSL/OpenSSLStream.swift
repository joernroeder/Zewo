import COpenSSL

public final class SSLStream : Stream {
	private let rawStream: Stream
	private let context: Context
	private let session: SSLSession
	private let readIO: IO
	private let writeIO: IO

	public var closed: Bool = false

	public init(context: Context, rawStream: Stream) throws {
		initialize()

		self.context = context
		self.rawStream = rawStream

		readIO = try IO()
		writeIO = try IO()

		session = try SSLSession(context: context)
		session.setIO(readIO: readIO, writeIO: writeIO)

		if let hostname = context.sniHostname {
			try session.setServerNameIndication(hostname: hostname)
		}

		if context.mode == .server {
			session.setAcceptState()
		} else {
			session.setConnectState()
		}
	}

	public func open(deadline: Double) throws {
		try rawStream.open(deadline: deadline)
		try handshake(deadline: deadline)
	}
    
    private func handshake(deadline: Double) throws {
        var rawBuffer = [UInt8](repeating: 0, count: 2048)
        try rawBuffer.withUnsafeMutableBufferPointer { buffer in
            func flushAndReceive() throws {
                try self.flush(deadline: deadline)
                let bytesRead = try self.rawStream.read(into: buffer, deadline: deadline)
                _ = try self.readIO.write(UnsafeBufferPointer<UInt8>(start: buffer.baseAddress!, count: bytesRead))
            }
            while !session.initializationFinished {
                do {
                    try session.handshake()
                } catch SSLSessionError.wantRead {
                    if context.mode == .client {
                        try flushAndReceive()
                    }
                }
                if context.mode == .server {
                    try flushAndReceive()
                }
            }
        }
	}

    public func read(into: UnsafeMutableBufferPointer<UInt8>, deadline: Double) throws -> Int {
        var rawBuffer = [UInt8](repeating: 0, count: 2048)
        while true {
            do {
                let bytesRead = try session.read(into: into)
                guard bytesRead > 0 else {
                    continue
                }
                return bytesRead
            } catch SSLSessionError.wantRead {
                do {
                    try rawBuffer.withUnsafeMutableBufferPointer { buffer in
                        let bytesRead = try self.rawStream.read(into: buffer, deadline: deadline)
                        _ = try self.readIO.write(UnsafeBufferPointer<UInt8>(start: buffer.baseAddress!, count: bytesRead))
                    }
                } catch StreamError.closedStream(let buffer) {
                    guard !buffer.isEmpty else {
                        throw StreamError.closedStream(buffer: Buffer())
                    }
                    _ = try buffer.withUnsafeBytes { bufferBytes in
                        try readIO.write(UnsafeBufferPointer<UInt8>(start: bufferBytes, count: buffer.count))
                    }
                    
                }
            } catch SSLSessionError.zeroReturn {
                throw StreamError.closedStream(buffer: Buffer())
            }
        }
    }

    
    public func write(_ buffer: UnsafeBufferPointer<UInt8>, deadline: Double) throws {
        var remaining = buffer
        while !remaining.isEmpty {
            let bytesWritten = try session.write(remaining)
            guard bytesWritten != remaining.count else {
                return
            }
            remaining = UnsafeBufferPointer(start: remaining.baseAddress!.advanced(by: bytesWritten),
                                            count: remaining.count - bytesWritten)
        }
    }
    
	public func flush(deadline: Double) throws {
        guard writeIO.pending > 0 else {
            return
        }
        
		do {
            let rawBufferCapacity = writeIO.pending
            let rawBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: rawBufferCapacity)
            defer {
                rawBuffer.deallocate(capacity: rawBufferCapacity)
            }
            let bytesRead = try writeIO.read(into: UnsafeMutableBufferPointer(start: rawBuffer, count: rawBufferCapacity))
            _ = try rawStream.write(UnsafeBufferPointer(start: rawBuffer, count: bytesRead), deadline: deadline)
			try rawStream.flush(deadline: deadline)
		} catch SSLIOError.shouldRetry { }
	}

	public func close() {
		// TODO: http://stackoverflow.com/questions/28056056/handling-ssl-shutdown-correctly
//		session.shutdown()
        rawStream.close()
	}
}

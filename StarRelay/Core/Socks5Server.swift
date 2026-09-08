import Foundation
import Darwin

// ============================================================================
// SOCKS5 服务端（无鉴权）：供 iOS 小火箭连接。等效安卓 Socks5Server.kt。
// 支持：CONNECT(TCP) 与 UDP ASSOCIATE。每转发一段数据即以“完整 IP 报文”
// 语义交给 onPacket（上层封装 + WS 上报）。使用 POSIX socket 便于 1:1 移植。
// ============================================================================

/// (up, proto, srcIp, sport, dstIp, dport, payload) —— up=true 上行(客户端->目标)
fileprivate typealias SocksPacketHandler = (_ up: Bool, _ proto: Int, _ srcIp: String, _ sport: Int,
                                            _ dstIp: String, _ dport: Int, _ payload: Data) -> Void

final class Socks5Server {
    private let port: Int
    private let onPacket: SocksPacketHandler
    private let onClientActive: (String) -> Void
    private let log: (String) -> Void

    private let lock = NSLock()
    private var running = false
    private var listenFd: Int32 = -1
    private var connFds = Set<Int32>()
    private var assocs: [String: Socks5UdpAssociate] = [:]

    init(port: Int,
         onPacket: @escaping SocksPacketHandler,
         onClientActive: @escaping (String) -> Void,
         log: @escaping (String) -> Void) {
        self.port = port
        self.onPacket = onPacket
        self.onClientActive = onClientActive
        self.log = log
    }

    // MARK: - 启停
    func start() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("SOCKS5 启动失败: 无法创建 socket")
            return false
        }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var sa = sockaddr4(ip: "0.0.0.0", port: port)
        let br = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard br == 0, listen(fd, 64) == 0 else {
            log("SOCKS5 启动失败: 端口 \(port) 可能被占用")
            close(fd)
            return false
        }
        lock.lock()
        running = true
        listenFd = fd
        lock.unlock()

        log("SOCKS5 已监听 :\(port)（iOS 小火箭填本机 IP:\(port)）")
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        return true
    }

    func stop() {
        lock.lock()
        running = false
        let lf = listenFd
        listenFd = -1
        let fds = connFds
        connFds.removeAll()
        let assocList = Array(assocs.values)
        assocs.removeAll()
        lock.unlock()

        if lf >= 0 { close(lf) }
        fds.forEach { close($0) }
        assocList.forEach { $0.close() }
        log("SOCKS5 已停止")
    }

    private func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func registerConn(_ fd: Int32) {
        lock.lock()
        if running { connFds.insert(fd) }
        lock.unlock()
    }

    private func unregisterConn(_ fd: Int32) {
        lock.lock(); connFds.remove(fd); lock.unlock()
    }

    // MARK: - 接受连接
    private func acceptLoop() {
        while isRunning() {
            let c = accept(listenFd, nil, nil)
            if c < 0 {
                if !isRunning() { break }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            registerConn(c)
            let peer = peerOf(c)
            Thread.detachNewThread { [weak self] in
                self?.handleClient(c, peerIp: peer?.ip ?? "")
                self?.unregisterConn(c)
            }
        }
    }

    // MARK: - SOCKS5 会话
    private func handleClient(_ c: Int32, peerIp: String) {
        // UDP ASSOCIATE 需把 c 作为控制连接保持到客户端断开，由其控制线程负责 close；
        // 其余路径都在本函数收尾时 close。
        var closeAtEnd = true
        defer { if closeAtEnd { close(c) } }

        guard let input = readFully(c, 2) else { return }           // VER NMETHODS
        let nmethods = Int(input[1])
        guard nmethods > 0, nmethods <= 255, readFully(c, nmethods) != nil else { return }
        guard writeAll(c, Data([5, 0])) else { return }             // 无鉴权

        guard let req = readFully(c, 4) else { return }
        let cmd = Int(req[1])
        let atyp = Int(req[3])
        guard let host = readSocksHost(c, atyp: atyp),
              let pb = readFully(c, 2) else { return }
        let dstPort = (Int(pb[0]) << 8) | Int(pb[1])
        let clientIp = peerIp.isEmpty ? "0.0.0.0" : peerIp
        let clientPort = portOf(c)

        switch cmd {
        case 1:
            onClientActive(clientIp)
            handleConnect(c, clientIp: clientIp, clientPort: clientPort, host: host, dstPort: dstPort)
        case 3:
            closeAtEnd = false      // 所有权转交 UDP 控制线程
            handleUdpAssociate(c, clientIp: clientIp, clientPort: clientPort)
        default:
            break
        }
    }

    private func readSocksHost(_ fd: Int32, atyp: Int) -> String? {
        switch atyp {
        case 1:
            guard let b = readFully(fd, 4) else { return nil }
            return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
        case 3:
            guard let l = readFully(fd, 1), l[0] > 0,
                  let name = readFully(fd, Int(l[0])) else { return nil }
            return String(data: name, encoding: .utf8)
        default:
            return nil      // ATYP=4(IPv6) 本链路不支持
        }
    }

    // MARK: - TCP CONNECT
    private func handleConnect(_ c: Int32, clientIp: String, clientPort: Int, host: String, dstPort: Int) {
        guard let dstIp = resolveIPv4(host) else {
            log("TCP CONNECT 目标解析失败 \(host):\(dstPort)")
            _ = writeAll(c, Data([5, 1, 0, 1, 0, 0, 0, 0, 0, 0]))
            return
        }
        guard let tfd = tcpConnect(ip: dstIp, port: dstPort, timeoutMs: 8000) else {
            log("TCP CONNECT 目标失败 \(host):\(dstPort)")
            _ = writeAll(c, Data([5, 1, 0, 1, 0, 0, 0, 0, 0, 0]))
            return
        }
        guard writeAll(c, Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])) else {
            close(tfd)
            return
        }
        log("TCP CONNECT <- \(clientIp) -> \(dstIp):\(dstPort)")

        // ---- 双向泵送（各占一线程循环转发 + 上报；信号量等待两端结束） ----
        let upSema = DispatchSemaphore(value: 0)
        let downSema = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = buf.withUnsafeMutableBytes { read(c, $0.baseAddress, 16384) }
                if n <= 0 { break }
                let chunk = Data(buf[0..<Int(n)])
                onPacket(true, IpPacket.protoTCP, clientIp, clientPort, dstIp, dstPort, chunk)
                guard writeAll(tfd, chunk) else { break }
            }
            shutdown(tfd, SHUT_WR)
            upSema.signal()
        }
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = buf.withUnsafeMutableBytes { read(tfd, $0.baseAddress, 16384) }
                if n <= 0 { break }
                let chunk = Data(buf[0..<Int(n)])
                onPacket(false, IpPacket.protoTCP, dstIp, dstPort, clientIp, clientPort, chunk)
                guard writeAll(c, chunk) else { break }
            }
            shutdown(c, SHUT_WR)
            downSema.signal()
        }
        upSema.wait()
        downSema.wait()
        close(tfd)
    }

    // MARK: - UDP ASSOCIATE
    private func handleUdpAssociate(_ c: Int32, clientIp: String, clientPort: Int) {
        let ufd = socket(AF_INET, SOCK_DGRAM, 0)
        guard ufd >= 0 else { return }
        var sa = sockaddr4(ip: "0.0.0.0", port: 0)
        let br = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(ufd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard br == 0 else { close(ufd); return }
        let localPort = portOf(ufd)
        // 回复 BND.ADDR=0.0.0.0 BND.PORT=UDP 本地端口
        guard writeAll(c, Data([5, 0, 0, 1, 0, 0, 0, 0,
                                UInt8(localPort >> 8), UInt8(localPort & 0xFF)])) else {
            close(ufd)
            return
        }
        log("UDP ASSOCIATE 建立 <- \(clientIp) (本地UDP端口 \(localPort))")
        onClientActive(clientIp)

        let assoc = Socks5UdpAssociate(serverSock: ufd, clientIp: clientIp, onPacket: onPacket)
        lock.lock()
        assocs["\(clientIp):\(clientPort)"] = assoc
        lock.unlock()

        Thread.detachNewThread { assoc.runRecvLoop() }      // 收 iOS UDP 封装
        // 阻塞读 TCP 控制连接，断开即收尾并关闭该控制 fd（等效安卓尾部循环）
        Thread.detachNewThread { [weak self, weak assoc] in
            var one = [UInt8](repeating: 0, count: 1)
            while one.withUnsafeMutableBytes({ read(c, $0.baseAddress, 1) }) > 0 {}
            assoc?.close()
            close(c)
            self?.lock.lock()
            self?.assocs.removeValue(forKey: "\(clientIp):\(clientPort)")
            self?.lock.unlock()
        }
    }
}

// MARK: - UDP 会话：从 iOS 收 SOCKS UDP 封装 → 转发目标 → 回包封装回 iOS
// iOS 的实际 UDP 源端口 ≠ TCP 控制连接端口，因此只按 IP 校验来源；
// 回包发给每个数据报的实际源地址（lastClient）。

fileprivate final class Socks5UdpAssociate {
    let serverSock: Int32
    let clientIp: String
    let onPacket: SocksPacketHandler

    private let lock = NSLock()
    private var closed = false
    private var lastClient: sockaddr_in?
    private var relays: [String: Socks5UdpRelay] = [:]

    init(serverSock: Int32, clientIp: String, onPacket: @escaping SocksPacketHandler) {
        self.serverSock = serverSock
        self.clientIp = clientIp
        self.onPacket = onPacket
    }

    func isClosed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    func close() {
        lock.lock()
        closed = true
        let rl = Array(relays.values)
        relays.removeAll()
        lock.unlock()
        close(serverSock)
        rl.forEach { $0.close() }
    }

    fileprivate func currentClient() -> sockaddr_in? {
        lock.lock(); defer { lock.unlock() }
        return lastClient
    }

    /// 阻塞接收 iOS 发来的 UDP 数据报
    func runRecvLoop() {
        var buf = [UInt8](repeating: 0, count: 65535)
        while !isClosed() {
            var from = sockaddr_storage()
            var fromLen = sockaddr_len()
            let n = buf.withUnsafeMutableBytes { rb -> ssize_t in
                withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { ap in
                        recvfrom(serverSock, rb.baseAddress, 65535, 0, ap, &fromLen)
                    }
                }
            }
            if n <= 0 {
                if !isClosed() { Thread.sleep(forTimeInterval: 0.02) }
                continue
            }
            guard let sin = sockaddrIn(from), ipString(sin) == clientIp else { continue }
            lock.lock()
            lastClient = sin
            lock.unlock()
            handleClientDatagram(Data(buf[0..<Int(n)]))
        }
    }

    private func handleClientDatagram(_ data: Data) {
        guard data.count >= 4 else { return }
        let bytes = [UInt8](data)
        let frag = bytes[2]
        if frag != 0 { return }                      // 不支持分片
        let atyp = bytes[3]
        var o = 4
        let targetHost: String
        switch atyp {
        case 1:
            guard o + 4 <= bytes.count else { return }
            targetHost = "\(bytes[o]).\(bytes[o + 1]).\(bytes[o + 2]).\(bytes[o + 3])"
            o += 4
        case 3:
            guard o + 1 <= bytes.count else { return }
            let len = Int(bytes[o]); o += 1
            guard o + len <= bytes.count else { return }
            targetHost = String(data: data.subdata(in: o..<o + len), encoding: .utf8) ?? ""
            o += len
        default:
            return
        }
        guard o + 2 <= bytes.count else { return }
        let dport = (Int(bytes[o]) << 8) | Int(bytes[o + 1]); o += 2
        guard o < bytes.count, !targetHost.isEmpty else { return }
        let payload = data.subdata(in: o..<data.count)
        guard let srcSin = currentClient() else { return }

        onPacket(true, IpPacket.protoUDP, clientIp, Int(srcSin.sin_port.bigEndian),
                 targetHost, dport, payload)

        let key = "\(targetHost):\(dport)"
        lock.lock()
        var relay = relays[key]
        if relay == nil {
            let r = Socks5UdpRelay(associate: self, targetHost: targetHost, targetPort: dport)
            relay = r
            relays[key] = r
        }
        let rl = relay
        lock.unlock()

        if let r = rl, r.prepareIfNeeded() {
            r.send(payload)
        }
    }
}

/// 每目标一个 UDP socket + 回包线程（等效安卓 relays / startReplyLoop）
fileprivate final class Socks5UdpRelay {
    private unowned let associate: Socks5UdpAssociate
    private let targetHost: String
    private let targetPort: Int

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var targetIp4 = ""
    private var targetSock4: sockaddr_in?
    private var prepared = false
    private var failed = false

    init(associate: Socks5UdpAssociate, targetHost: String, targetPort: Int) {
        self.associate = associate
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    func close() {
        lock.lock()
        let f = fd
        fd = -1
        lock.unlock()
        if f >= 0 { close(f) }
    }

    /// 首次使用时解析目标 + 创建 socket + 启动回包线程；失败不再重试
    func prepareIfNeeded() -> Bool {
        lock.lock()
        if prepared { let ok = fd >= 0; lock.unlock(); return ok }
        if failed { lock.unlock(); return false }
        guard let ip = resolveIPv4(targetHost, SOCK_DGRAM) else {
            failed = true
            lock.unlock()
            return false
        }
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else {
            failed = true
            lock.unlock()
            return false
        }
        fd = s
        targetIp4 = ip
        targetSock4 = sockaddr4(ip: ip, port: targetPort)
        prepared = true
        lock.unlock()
        Thread.detachNewThread { [weak self] in self?.replyLoop() }
        return true
    }

    func send(_ payload: Data) {
        guard !payload.isEmpty else { return }
        lock.lock()
        guard let sin = targetSock4 else { lock.unlock(); return }
        let s = fd
        lock.unlock()
        guard s >= 0 else { return }
        var target = sin
        _ = payload.withUnsafeBytes { rb -> ssize_t in
            withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(s, rb.baseAddress, payload.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// 回包线程：读目标回复 → 封装 SOCKS UDP 头 → 发回 iOS（lastClient）
    private func replyLoop() {
        var buf = [UInt8](repeating: 0, count: 65535)
        while true {
            lock.lock()
            if fd < 0 { lock.unlock(); break }
            let s = fd
            lock.unlock()
            var from = sockaddr_storage()
            var fromLen = sockaddr_len()
            let n = buf.withUnsafeMutableBytes { rb -> ssize_t in
                withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { ap in
                        recvfrom(s, rb.baseAddress, 65535, 0, ap, &fromLen)
                    }
                }
            }
            if n <= 0 {
                if associate.isClosed() { break }
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            // 回包封装仅支持 IPv4 来源目标（等效安卓 ra.size != 4 则跳过）
            guard let src = sockaddrIn(from) else { continue }
            let ra = ipv4Bytes(src)
            var replyTo: sockaddr_in
            lock.lock()
            replyTo = associate.currentClient() ?? sockaddr4(ip: "0.0.0.0", port: 0)
            let tIp = targetIp4
            let tPort = targetPort
            lock.unlock()
            if replyTo.sin_addr.s_addr == 0 { continue }

            let payload = Data(buf[0..<Int(n)])
            // 头：RSV=0 FRAG=0 ATYP=1 + 目标真实IP + 目标端口
            var head = [UInt8](repeating: 0, count: 10)
            head[3] = 1
            for (i, b) in ra.enumerated() { head[4 + i] = b }
            head[8] = UInt8(tPort >> 8)
            head[9] = UInt8(tPort & 0xFF)
            let reply = Data(head) + payload

            associate.onPacket(false, IpPacket.protoUDP, tIp, tPort,
                               associate.clientIp, Int(replyTo.sin_port.bigEndian), payload)

            _ = reply.withUnsafeBytes { rb -> ssize_t in
                withUnsafePointer(to: &replyTo) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(associate.serverSock, rb.baseAddress, reply.count, 0, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }
}

// MARK: - POSIX 辅助

private func sockaddr_len() -> socklen_t { socklen_t(MemoryLayout<sockaddr_storage>.size) }

private func sockaddr4(ip: String, port: Int) -> sockaddr_in {
    var sa = sockaddr_in()
    sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sa.sin_family = sa_family_t(AF_INET)
    sa.sin_port = in_port_t(UInt16(port).bigEndian)
    ip.withCString { cs in _ = inet_pton(AF_INET, cs, &sa.sin_addr) }
    return sa
}

/// sockaddr_storage -> sockaddr_in（仅 IPv4）
private func sockaddrIn(_ ss: sockaddr_storage) -> sockaddr_in? {
    guard ss.ss_family == sa_family_t(AF_INET) else { return nil }
    return withUnsafePointer(to: ss) {
        $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }
}

private func ipv4Bytes(_ sin: sockaddr_in) -> [UInt8] {
    let n = sin.sin_addr.s_addr.bigEndian
    return [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
}

private func ipString(_ sin: sockaddr_in) -> String {
    var s = sin
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    buf.withUnsafeMutableBufferPointer {
        _ = inet_ntop(AF_INET, &s.sin_addr, $0.baseAddress, socklen_t(INET_ADDRSTRLEN))
    }
    return String(cString: buf)
}

private func ipString(_ addr: UnsafePointer<sockaddr>) -> String? {
    guard addr.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
    let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    return ipString(sin)
}

private func isIPv4Literal(_ host: String) -> Bool {
    var a = in_addr()
    return host.withCString { inet_pton(AF_INET, $0, &a) == 1 }
}

/// 解析主机名为 IPv4（本机链路仅支持 IPv4 目标）
private func resolveIPv4(_ host: String, _ socktype: Int32 = SOCK_STREAM) -> String? {
    if isIPv4Literal(host) { return host }
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = socktype
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &res) == 0 else { return nil }
    defer { freeaddrinfo(res) }
    guard let r = res else { return nil }
    return ipString(r.pointee.ai_addr)
}

/// 获取对端 (ip, port)
private func peerOf(_ fd: Int32) -> (ip: String, port: Int)? {
    var ss = sockaddr_storage()
    var len = sockaddr_len()
    let r = withUnsafeMutablePointer(to: &ss) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
    }
    guard r == 0, let sin = sockaddrIn(ss) else { return nil }
    return (ipString(sin), Int(sin.sin_port.bigEndian))
}

private func portOf(_ fd: Int32) -> Int {
    var ss = sockaddr_storage()
    var len = sockaddr_len()
    let r = withUnsafeMutablePointer(to: &ss) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    guard r == 0, let sin = sockaddrIn(ss) else { return 0 }
    return Int(sin.sin_port.bigEndian)
}

/// TCP 非阻塞连接（poll 8s 超时）
private func tcpConnect(ip: String, port: Int, timeoutMs: Int) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    var sa = sockaddr4(ip: ip, port: port)
    let rc = withUnsafePointer(to: &sa) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if rc < 0 {
        if errno != EINPROGRESS {
            close(fd)
            return nil
        }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pr = poll(&p, 1, Int32(timeoutMs))
        if pr <= 0 || (p.revents & Int16(POLLERR)) != 0 {
            close(fd)
            return nil
        }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0 || err != 0 {
            close(fd)
            return nil
        }
    }
    flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    return fd
}

/// 读满 n 字节；EOF/出错返回 nil
private func readFully(_ fd: Int32, _ n: Int) -> Data? {
    guard n > 0 else { return Data() }
    var out = Data()
    var buf = [UInt8](repeating: 0, count: n)
    while out.count < n {
        let want = n - out.count
        let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, want) }
        if r <= 0 { return nil }
        out.append(buf.prefix(Int(r)))
    }
    return out
}

/// 写完全部数据
@discardableResult
private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var sent = 0
    while sent < data.count {
        let w = data.withUnsafeBytes { raw -> ssize_t in
            guard let base = raw.baseAddress else { return 0 }
            return write(fd, base.advanced(by: sent), data.count - sent)
        }
        if w <= 0 { return false }
        sent += Int(w)
    }
    return true
}

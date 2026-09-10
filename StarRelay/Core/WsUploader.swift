import Foundation

/// WebSocket 逐包上报器（等效安卓 WsUploader.kt / 转发器 WsMirrorServer 协议兼容）：
///   连接 ws://服务器:1082，鉴权 {"type":"auth","api_key":"32位hex"}（api_key 既是鉴权凭据也是房间号）；
///   每包一条 {"batch":[{"data":"base64(完整IP报文)"}]}，单线程保证顺序逐条发送；
///   断线自动重连，重连期间队列积压（超限丢最旧）。
final class WsUploader: NSObject, URLSessionWebSocketDelegate {
    private let url: URL
    private let apiKey: String
    private let log: (String) -> Void

    private let lock = NSLock()
    private var stopFlag = false
    private var queue: [String] = []
    private let maxQueue = 20000

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var connected = false        // 传输层已连接
    private var ready = false            // 已鉴权，可发送数据
    private var lastSendTime = Date.distantPast
    private var pendingSema: DispatchSemaphore?

    init(urlString: String, apiKey: String, log: @escaping (String) -> Void) {
        self.url = URL(string: urlString) ?? URL(string: "ws://127.0.0.1:1082")!
        self.apiKey = apiKey
        self.log = log
        super.init()
    }

    // MARK: - 对外接口
    func start() {
        stopFlag = false
        Thread.detachNewThread { [weak self] in self?.runLoop() }
    }

    func stop() {
        lock.lock()
        stopFlag = true
        connected = false
        ready = false
        let t = task
        let s = session
        lock.unlock()
        t?.cancel()
        s?.invalidateAndCancel()
    }

    func isConnected() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return connected && ready
    }

    /// 上报一段完整 IP 报文（等效安卓 enqueueIp）
    func enqueueIp(_ ipPacket: Data) {
        guard !ipPacket.isEmpty else { return }
        let b64 = ipPacket.base64EncodedString()
        let msg = "{\"batch\":[{\"data\":\"\(b64)\"}]}"
        lock.lock()
        if stopFlag {
            lock.unlock()
            return
        }
        if queue.count >= maxQueue {
            queue.removeFirst()          // 丢最旧，防内存膨胀
        }
        queue.append(msg)
        lock.unlock()
    }

    // MARK: - 主循环（等效安卓 runLoop）
    private func runLoop() {
        while true {
            lock.lock(); let stop = stopFlag; lock.unlock()
            if stop { return }

            lock.lock(); let isReady = ready; lock.unlock()
            if !isReady {
                _ = connect()
                lock.lock(); let r = ready; let st = stopFlag; lock.unlock()
                if st { return }
                if !r { Thread.sleep(forTimeInterval: 1.2) }   // 断线重连间隔
                continue
            }

            let m = popQueue()
            if let msg = m {
                if !sendText(msg) {
                    markDisconnected("重连中")
                    cancelTask()
                }
            } else {
                // 空闲心跳：转发器据此保活，发送失败触发重连
                lock.lock(); let last = lastSendTime; lock.unlock()
                if Date().timeIntervalSince(last) > 15 {
                    if !sendText("{\"type\":\"ping\"}") {
                        markDisconnected("重连中")
                        cancelTask()
                    }
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    /// 建立连接并等待握手/鉴权完成（阻塞至多 ~6s）
    private func connect() -> Bool {
        lock.lock()
        guard !stopFlag else { lock.unlock(); return false }
        // 丢弃上一轮残留连接（可能仍在超时重试中），避免多个 session 并存
        let oldSession = session
        session = nil
        task = nil
        let sema = DispatchSemaphore(value: 0)
        pendingSema = sema
        lock.unlock()
        oldSession?.invalidateAndCancel()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0          // 长连接不断（不因空闲超时）
        config.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        let t = session.webSocketTask(with: url)
        lock.lock()
        self.session = session
        self.task = t
        lock.unlock()
        t.resume()

        // 等待 didOpen/didFail 结果（最多 6s）
        _ = sema.wait(timeout: .now() + 6)

        lock.lock(); let opened = connected; let st = stopFlag; lock.unlock()
        if !opened {
            if !st {
                State.shared.setWsState("连接失败")
                State.shared.setLastError("WS 连接失败：转发器 \(url.absoluteString) 不可达（6s 超时）")
                log("[ws] 连接失败：6 秒内未完成握手 → 检查①星辰雷达的「本地网络」权限 ②手机与转发器同网段 ③服务器地址:\(url.absoluteString)")
            }
            return false
        }

        // 鉴权（若配置了房间Key）必须最先发送
        if !apiKey.isEmpty {
            let ok = sendText("{\"type\":\"auth\",\"api_key\":\"\(apiKey)\"}")
            if !ok {
                markDisconnected("鉴权失败")
                cancelTask()
                return false
            }
        }
        lock.lock()
        ready = true
        let t2 = task
        lock.unlock()
        State.shared.setWsState("已连接")
        State.shared.log("[ws] 已连接 \(url.absoluteString)")
        startReceiveLoop(t2)
        return true
    }

    /// 保持接收，以便及时感知对端断开/协议帧
    private func startReceiveLoop(_ t: URLSessionWebSocketTask?) {
        guard let t = t else { return }
        t.receive { [weak self, weak t] result in
            guard let self = self, let t = t else { return }
            switch result {
            case .success:
                self.startReceiveLoop(t)          // 转发器只回 auth_ok/pong，忽略内容继续收
            case .failure:
                // 底层断开：标记后由主循环重连
                self.lock.lock(); let stop = self.stopFlag; self.lock.unlock()
                if !stop {
                    self.markDisconnected("已断开")
                    self.cancelTask()
                }
            }
        }
    }

    /// 串行发送（阻塞等待结果，等效安卓 sendText）
    private func sendText(_ s: String) -> Bool {
        lock.lock()
        guard let t = task else { lock.unlock(); return false }
        lock.unlock()
        var ok = false
        let sema = DispatchSemaphore(value: 0)
        t.send(.string(s)) { err in
            ok = (err == nil)
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 8)
        if ok {
            lock.lock()
            lastSendTime = Date()
            lock.unlock()
            if s.hasPrefix("{\"batch\"") { State.shared.addSent() }
        }
        return ok
    }

    // MARK: - 内部状态
    private func popQueue() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    private func markDisconnected(_ state: String) {
        lock.lock()
        connected = false
        ready = false
        lock.unlock()
        State.shared.setWsState(state)
    }

    private func cancelTask() {
        lock.lock()
        let t = task
        task = nil
        lock.unlock()
        t?.cancel()
    }

    // MARK: - URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        lock.lock()
        guard self.session === session else { lock.unlock(); return }   // 忽略旧 session
        connected = true
        pendingSema?.signal()
        pendingSema = nil
        lock.unlock()
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        lock.lock()
        guard self.session === session else { lock.unlock(); return }   // 忽略旧 session
        connected = false
        ready = false
        pendingSema?.signal()
        pendingSema = nil
        lock.unlock()
        State.shared.setWsState("已断开")
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // 旧 session 失效/取消也会走到这里，必须只处理当前 session，避免覆盖新连接状态
        lock.lock()
        let current = self.session === session
        if current {
            connected = false
            ready = false
            pendingSema?.signal()
            pendingSema = nil
        }
        lock.unlock()
        guard current else { return }
        if let e = error {
            State.shared.setWsState("连接失败")
            State.shared.setLastError("WS 连接失败：\(e.localizedDescription)")
            log("[ws] 连接异常: \(e.localizedDescription)")
        }
    }
}

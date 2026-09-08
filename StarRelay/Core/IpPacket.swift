import Foundation

/// 把 SOCKS5 通道捕获的一段数据（五元组 + 载荷）封装成“完整 IPv4 报文”，
/// 与转发器 WsMirrorServer / IpPacketParser 的解析格式完全一致（等效安卓 IpPacket.kt）：
///   [IPv4头][TCP头|UDP头][载荷]
enum IpPacket {
    static let protoTCP = 6
    static let protoUDP = 17
    private static let maxPayload = 1400   // 单包载荷上限（贴合 MTU）

    /// 封装一段载荷为 IPv4 报文；载荷超长自动截断。
    static func wrap(proto: Int, srcIp: String, dstIp: String, sport: Int, dport: Int, payload: Data) -> Data {
        let pl: Data = payload.count > maxPayload ? payload.prefix(maxPayload) : payload
        let transHead = proto == protoTCP ? 20 : 8          // TCP 20B / UDP 8B
        let total = 20 + transHead + pl.count
        var buf = [UInt8](repeating: 0, count: total)

        // ---- IPv4 头 ----
        buf[0] = 0x45                                    // v4 + IHL=5
        put16(&buf, 2, total)                            // total length
        put16(&buf, 4, 0x4711)                           // identification
        // flags/frag = 0（buf[6..7] 已为 0）
        buf[8] = 64                                      // TTL
        buf[9] = UInt8(proto)
        put16(&buf, 10, 0)                               // checksum（回填）
        copyIPv4(srcIp, into: &buf, at: 12)
        copyIPv4(dstIp, into: &buf, at: 16)

        // ---- 传输层头 ----
        put16(&buf, 20, sport)
        put16(&buf, 22, dport)
        if proto == protoTCP {
            buf[20 + 12] = 0x50                          // data offset = 5
            buf[20 + 13] = 0x10                          // ACK
        } else {
            put16(&buf, 24, 8 + pl.count)                // UDP length
        }

        pl.enumerated().forEach { buf[20 + transHead + $0.offset] = $0.element }

        // ---- 校验和 ----
        put16(&buf, 10, checksum(Array(buf[0..<20])))
        return Data(buf)
    }

    /// 点分 IPv4 -> 4 字节；失败填 0。
    private static func copyIPv4(_ ip: String, into buf: inout [UInt8], at off: Int) {
        var dst = in_addr(s_addr: 0)
        if ip.withCString({ inet_pton(AF_INET, $0, &dst) }) == 1 {
            let n = dst.s_addr.bigEndian
            buf[off] = UInt8((n >> 24) & 0xFF)
            buf[off + 1] = UInt8((n >> 16) & 0xFF)
            buf[off + 2] = UInt8((n >> 8) & 0xFF)
            buf[off + 3] = UInt8(n & 0xFF)
        }
    }

    private static func put16(_ buf: inout [UInt8], _ off: Int, _ v: Int) {
        buf[off] = UInt8((v >> 8) & 0xFF)
        buf[off + 1] = UInt8(v & 0xFF)
    }

    private static func checksum(_ data: [UInt8]) -> Int {
        var sum: UInt32 = 0
        var i = 0
        let end = data.count
        while i < end - 1 {
            sum += UInt32(data[i]) << 8 | UInt32(data[i + 1])
            i += 2
        }
        if i < end { sum += UInt32(data[i]) << 8 }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        return Int((~sum) & 0xFFFF)
    }
}

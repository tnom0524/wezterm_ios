/// UniFFI生成の `connect(addr:delegate:)` をラップ。
/// ConnectionStore内での命名衝突を避けるためにここで別名を付ける。
func rustConnect(addr: String, delegate: ClientDelegate) throws -> MuxClient {
    return try connect(addr: addr, delegate: delegate)
}

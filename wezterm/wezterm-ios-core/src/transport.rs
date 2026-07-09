//! トランスポート抽象（poc-attach v1 から流用、TCPのみ残す）。
//!
//! muxプロトコルは双方向バイトストリームの上に載っているだけなので、
//! read半分とwrite半分に分離できれば良い。iOS版では将来ここを
//! Network.framework の TCP コネクションへ差し替える想定。

use anyhow::Context;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream};

/// トランスポートを read/write/クリーンアップの3つに分解した結果。
pub struct Split {
    pub reader: Box<dyn Read + Send>,
    pub writer: Box<dyn Write + Send>,
    /// 終了時に呼ぶ後片付け（ソケットの shutdown 等）。
    pub cleanup: Box<dyn FnMut() + Send>,
}

/// read半分とwrite半分に分離できるトランスポート。
pub trait Transport {
    fn split(self: Box<Self>) -> anyhow::Result<Split>;
}

/// 素のTCP直結。サーバー側で unix ソケットを socat 等で TCP 公開している前提。
pub struct TcpTransport {
    pub addr: String,
}

impl Transport for TcpTransport {
    fn split(self: Box<Self>) -> anyhow::Result<Split> {
        let stream = TcpStream::connect(&self.addr)
            .with_context(|| format!("TCP接続に失敗: {}", self.addr))?;
        stream.set_nodelay(true).ok();
        let reader = stream.try_clone().context("TcpStream::try_clone に失敗")?;
        let cleanup_stream = stream.try_clone().context("TcpStream::try_clone に失敗")?;
        let cleanup = Box::new(move || {
            let _ = cleanup_stream.shutdown(Shutdown::Both);
        });
        Ok(Split {
            reader: Box::new(reader),
            writer: Box::new(stream),
            cleanup,
        })
    }
}

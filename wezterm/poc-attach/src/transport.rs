//! トランスポート抽象。
//!
//! muxプロトコルは「双方向のバイトストリーム」の上に載っているだけなので、
//! ストリームさえ差し替えられれば ssh 子プロセスでも素の TCP でも動く。
//! iOS版ではここを Network.framework の TCP コネクションに差し替える想定。
//!
//! 要件（DESIGN-v1）: read半分 と write半分 に分離できること。
//! 読みスレッドが reader を占有し、メインスレッドが writer を占有する。

use anyhow::Context;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream};
use std::process::{Command, Stdio};

/// トランスポートを read/write/クリーンアップの3つに分解した結果。
pub struct Split {
    pub reader: Box<dyn Read + Send>,
    pub writer: Box<dyn Write + Send>,
    /// 終了時に呼ぶ後片付け（ssh子プロセスのkill、ソケットのshutdown等）。
    pub cleanup: Box<dyn FnMut() + Send>,
}

/// read半分とwrite半分に分離できるトランスポート。
pub trait Transport {
    fn split(self: Box<Self>) -> anyhow::Result<Split>;
}

/// 本家SSHドメインと同じ方式:
///   ssh -T <host> "wezterm cli --prefer-mux proxy"
/// の子プロセスのstdioにPduを流す。
pub struct SshTransport {
    pub host: String,
}

impl Transport for SshTransport {
    fn split(self: Box<Self>) -> anyhow::Result<Split> {
        let mut child = Command::new("ssh")
            .arg("-T") // ~/.ssh/config の RequestTTY yes を打ち消す（ttyはバイナリを壊す）
            .arg(&self.host)
            .arg("wezterm cli --prefer-mux proxy")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .context("ssh の起動に失敗")?;
        let writer = child.stdin.take().unwrap();
        let reader = child.stdout.take().unwrap();
        // Child を cleanup クロージャに移動して所有させる（drop されても
        // Rust は自動killしないため、明示的に kill する）
        let cleanup = Box::new(move || {
            let _ = child.kill();
            let _ = child.wait();
        });
        Ok(Split {
            reader: Box::new(reader),
            writer: Box::new(writer),
            cleanup,
        })
    }
}

/// 素のTCP直結。サーバー側で unix ソケットを socat 等で TCP 公開している前提。
/// iOSクライアントはこちらを使う（子プロセスを起動できないため）。
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

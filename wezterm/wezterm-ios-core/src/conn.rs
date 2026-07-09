//! muxプロトコルのコネクション層（poc-attach v1 から流用・改変）。
//!
//! 読みスレッドが `Pdu::decode` をループし、結果を単一の mpsc チャネルへ流す。
//! エンジンスレッド（lib.rs）は同じチャネルから:
//!   - サーバー由来のPDU（応答 or 通知）
//!   - MuxClient メソッドから注入された Command
//! を1本の `recv` で受けて処理する。
//!
//! RPC（応答待ち）の最中に届いた通知や Command は `pending` に退避し、
//! 応答受領後にエンジンループが順番どおり処理する（取りこぼし・順序崩れ防止）。

use crate::transport::{Split, Transport};
use crate::Command;
use anyhow::Context;
use codec::{DecodedPdu, Pdu};
use std::collections::VecDeque;
use std::io::Write;
use std::sync::mpsc::{Receiver, Sender};

/// エンジンループが処理する事象。
pub enum Event {
    /// サーバーから届いたPDU（応答 or 通知）。
    Pdu(DecodedPdu),
    /// MuxClient のメソッド呼び出しから注入された命令。
    Command(Command),
    /// 読みスレッドがEOF/エラーに達した（接続断）。
    Eof,
}

pub struct Conn {
    writer: Box<dyn Write + Send>,
    events: Receiver<Event>,
    /// イベントチャネルへの追加送信口（MuxClient へ配る用）。
    event_tx: Sender<Event>,
    /// RPC待機中に先読みしてしまった非対象イベントの退避先。
    pending: VecDeque<Event>,
    serial: u64,
    cleanup: Box<dyn FnMut() + Send>,
}

impl Conn {
    /// トランスポートを起動し、読みスレッドを立ち上げる。
    pub fn connect(transport: Box<dyn Transport>) -> anyhow::Result<Self> {
        let Split {
            mut reader,
            writer,
            cleanup,
        } = transport.split()?;

        let (tx, rx) = std::sync::mpsc::channel::<Event>();
        let reader_tx = tx.clone();
        // 読みスレッド: EOF/エラーまで Pdu::decode をループ
        std::thread::spawn(move || loop {
            match Pdu::decode(&mut reader) {
                Ok(decoded) => {
                    if reader_tx.send(Event::Pdu(decoded)).is_err() {
                        break; // エンジン側が終了した
                    }
                }
                Err(_) => {
                    let _ = reader_tx.send(Event::Eof);
                    break;
                }
            }
        });

        Ok(Self {
            writer,
            events: rx,
            event_tx: tx,
            pending: VecDeque::new(),
            serial: 0,
            cleanup,
        })
    }

    /// MuxClient が Command を注入するための送信口。
    pub fn event_sender(&self) -> Sender<Event> {
        self.event_tx.clone()
    }

    /// PDUを送信し、割り当てたserialを返す（応答は待たない）。
    pub fn send(&mut self, pdu: Pdu) -> anyhow::Result<u64> {
        self.serial += 1;
        let s = self.serial;
        pdu.encode(&mut self.writer, s)
            .context("PDUのencodeに失敗")?;
        self.writer.flush().context("flushに失敗")?;
        Ok(s)
    }

    /// PDUを送り、同じserialの応答が返るまで待つ。
    /// その間に届いた通知や Command は `pending` に退避する。
    pub fn rpc(&mut self, pdu: Pdu) -> anyhow::Result<Pdu> {
        let s = self.send(pdu)?;
        loop {
            let ev = self.events.recv().context("読みスレッドが停止した")?;
            match ev {
                Event::Pdu(d) if d.serial == s => {
                    if let Pdu::ErrorResponse(e) = d.pdu {
                        anyhow::bail!("サーバーがErrorResponse: {}", e.reason);
                    }
                    return Ok(d.pdu);
                }
                Event::Eof => anyhow::bail!("応答待ち中に接続が切れた"),
                other => self.pending.push_back(other),
            }
        }
    }

    /// 次のイベントを1つ取り出す（退避分を優先）。ブロッキング。
    pub fn next_event(&mut self) -> anyhow::Result<Event> {
        if let Some(ev) = self.pending.pop_front() {
            return Ok(ev);
        }
        self.events.recv().context("読みスレッドが停止した")
    }
}

impl Drop for Conn {
    fn drop(&mut self) {
        (self.cleanup)();
    }
}

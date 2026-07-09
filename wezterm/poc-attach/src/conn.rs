//! muxプロトコルのコネクション層。
//!
//! 読みスレッドが `Pdu::decode` をループし、デコード結果を
//! 単一の mpsc チャネルへ流す。メインスレッド（本モジュールの `Conn`）は
//! そのチャネルから:
//!   - serial != 0 の応答 → 発行中のRPCへ
//!   - serial == 0 の通知 → イベントとしてメインループへ
//! を振り分ける。
//!
//! stdin からのバイト入力や SIGWINCH も同じイベントチャネルへ合流させ、
//! メインループが1本の `recv` で全事象を待てるようにしている
//! （std の mpsc は複数チャネルの select ができないため）。

use crate::transport::{Split, Transport};
use anyhow::Context;
use codec::{DecodedPdu, Pdu};
use std::collections::VecDeque;
use std::io::Write;
use std::sync::mpsc::{Receiver, Sender};
use std::time::Instant;

/// メインループが処理する事象。
pub enum Event {
    /// サーバーから届いたPDU（応答 or 通知）。
    Pdu(DecodedPdu),
    /// ローカル端末(stdin)から読んだ生バイト。
    Input(Vec<u8>),
    /// SIGWINCH（端末リサイズ）。
    Resize,
    /// stdin/読みスレッドがEOFに達した。
    Eof,
}

pub struct Conn {
    writer: Box<dyn Write + Send>,
    events: Receiver<Event>,
    /// イベントチャネルへの追加送信口（stdinスレッドやSIGWINCHへ配る用）。
    event_tx: Sender<Event>,
    /// RPC待機中に先読みしてしまった非対象イベントの退避先。
    /// メインループは channel より先にここを消費する。
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
                        break; // メイン側が終了した
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

    /// stdinスレッドやSIGWINCHハンドラへ渡すための送信口。
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
    /// その間に届いた通知や入力イベントは `pending` に退避し、
    /// 後段のメインループで順番どおり処理させる（取りこぼし防止）。
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

    /// 締切付きで次のイベントを取り出す。タイムアウト時は Ok(None)。
    pub fn next_event_until(&mut self, deadline: Instant) -> anyhow::Result<Option<Event>> {
        if let Some(ev) = self.pending.pop_front() {
            return Ok(Some(ev));
        }
        let now = Instant::now();
        if now >= deadline {
            return Ok(None);
        }
        match self.events.recv_timeout(deadline - now) {
            Ok(ev) => Ok(Some(ev)),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => Ok(None),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                anyhow::bail!("読みスレッドが停止した")
            }
        }
    }

}

impl Drop for Conn {
    fn drop(&mut self) {
        (self.cleanup)();
    }
}

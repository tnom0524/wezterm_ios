//! 修復ツール: mux サーバー上の 1 ペインへ、pixel/dpi も含めた寸法を Resize PDU で直接送る。
//! GUI クライアントがキャッシュと同じ寸法を再送しない（＝サーバー側だけが食い違う）
//! 状態を、GUI 側が持っている寸法をそのまま書き戻して解消するのに使う。
//!
//!   WEZTERM_MUX_ADDR=127.0.0.1:17799 cargo run -p wezterm-ios-core --example set_pane_size -- \
//!       <tab_id> <pane_id> <rows> <cols> <pixel_width> <pixel_height> <dpi>

use codec::{GetCodecVersion, Pdu, Resize, SetClientId, CODEC_VERSION};
use mux::client::ClientId;
use std::io::Write;
use std::net::TcpStream;
use wezterm_term::TerminalSize;

fn rpc(w: &mut TcpStream, r: &mut TcpStream, serial: &mut u64, pdu: Pdu) -> anyhow::Result<Pdu> {
    *serial += 1;
    pdu.encode(&mut *w, *serial)?;
    w.flush()?;
    loop {
        let d = Pdu::decode(&mut *r)?;
        if d.serial == *serial {
            if let Pdu::ErrorResponse(e) = d.pdu {
                anyhow::bail!("ErrorResponse: {}", e.reason);
            }
            return Ok(d.pdu);
        }
    }
}

fn main() -> anyhow::Result<()> {
    let addr = std::env::var("WEZTERM_MUX_ADDR").expect("set WEZTERM_MUX_ADDR");
    let a: Vec<usize> = std::env::args().skip(1).map(|s| s.parse().expect("integer")).collect();
    anyhow::ensure!(a.len() == 7, "usage: <tab_id> <pane_id> <rows> <cols> <pixel_width> <pixel_height> <dpi>");
    let mut w = TcpStream::connect(&addr)?;
    let mut r = w.try_clone()?;
    let mut serial = 0;
    match rpc(&mut w, &mut r, &mut serial, Pdu::GetCodecVersion(GetCodecVersion {}))? {
        Pdu::GetCodecVersionResponse(v) => anyhow::ensure!(v.codec_vers == CODEC_VERSION, "codec mismatch"),
        other => anyhow::bail!("unexpected {}", other.pdu_name()),
    }
    rpc(&mut w, &mut r, &mut serial, Pdu::SetClientId(SetClientId { client_id: ClientId::new() }))?;
    let size = TerminalSize { rows: a[2], cols: a[3], pixel_width: a[4], pixel_height: a[5], dpi: a[6] as u32 };
    rpc(&mut w, &mut r, &mut serial, Pdu::Resize(Resize { containing_tab_id: a[0], pane_id: a[1], size }))?;
    println!("ok: tab {} pane {} -> {:?}", a[0], a[1], size);
    Ok(())
}

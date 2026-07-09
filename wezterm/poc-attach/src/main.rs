//! ヘッドレスPoC v1: GUIなしで wezterm mux にアタッチする対話クライアント。
//!
//! これはiOSアプリのRustコア層の原型。証明したいこと:
//!   1. キー入力を送れる（WriteToPane）
//!   2. サーバーのプッシュ（serial=0 の GetPaneRenderChangesResponse）で画面追従
//!   3. トランスポートを差し替えられる（ssh子プロセス ⇔ 素のTCP）
//!
//! CLI:
//!   poc-attach <transport> <mode>
//!     transport: ssh <host> | tcp <addr:port>
//!     mode:      list | attach [pane_id] | selftest

mod conn;
mod pane_state;
mod raw_tty;
mod transport;

use anyhow::Context;
use codec::{
    GetCodecVersion, GetLines, GetPaneRenderChanges, ListPanes, Pdu, SetClientId, SpawnV2,
    WriteToPane, CODEC_VERSION,
};
use conn::{Conn, Event};
use mux::client::ClientId;
use mux::pane::PaneId;
use mux::tab::{PaneEntry, PaneNode};
use pane_state::PaneState;
use std::io::{Read, Write};
use std::time::{Duration, Instant};
use transport::{SshTransport, TcpTransport, Transport};
use wezterm_term::TerminalSize;

fn main() {
    if let Err(e) = run() {
        eprintln!("エラー: {:#}", e);
        std::process::exit(1);
    }
}

fn run() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    // args[1]=transport種別, args[2]=transport引数, args[3]=mode, args[4]=省略可(pane_id)
    let transport_kind = args.get(1).map(|s| s.as_str()).unwrap_or("");
    let transport_arg = args.get(2).cloned().unwrap_or_default();
    let mode = args.get(3).map(|s| s.as_str()).unwrap_or("list");

    let transport: Box<dyn Transport> = match transport_kind {
        "ssh" => {
            anyhow::ensure!(!transport_arg.is_empty(), "ssh には <host> が必要");
            Box::new(SshTransport {
                host: transport_arg,
            })
        }
        "tcp" => {
            anyhow::ensure!(!transport_arg.is_empty(), "tcp には <addr:port> が必要");
            Box::new(TcpTransport {
                addr: transport_arg,
            })
        }
        other => anyhow::bail!(
            "使い方: poc-attach <ssh <host> | tcp <addr:port>> <list|attach [pane_id]|selftest>\n\
             （transport種別 '{}' は不明）",
            other
        ),
    };

    let mut c = Conn::connect(transport)?;

    match mode {
        "list" => mode_list(&mut c),
        "attach" => {
            let pane_id = args.get(4).and_then(|s| s.parse::<PaneId>().ok());
            mode_attach(&mut c, pane_id)
        }
        "selftest" => mode_selftest(&mut c),
        other => anyhow::bail!("mode '{}' は不明（list|attach|selftest）", other),
    }
}

/// バージョンハンドシェイク + SetClientId。
fn handshake(c: &mut Conn) -> anyhow::Result<()> {
    let resp = c.rpc(Pdu::GetCodecVersion(GetCodecVersion {}))?;
    match resp {
        Pdu::GetCodecVersionResponse(v) => {
            anyhow::ensure!(
                v.codec_vers == CODEC_VERSION,
                "codecバージョン不一致: local={} remote={}",
                CODEC_VERSION,
                v.codec_vers
            );
        }
        other => anyhow::bail!("GetCodecVersionへの予期しない応答: {}", other.pdu_name()),
    }
    // クライアント識別子を通知（本家クライアントと同じ手順）
    c.rpc(Pdu::SetClientId(SetClientId {
        client_id: ClientId::new(),
    }))?;
    Ok(())
}

fn collect_leaves(node: &PaneNode, out: &mut Vec<PaneEntry>) {
    match node {
        PaneNode::Empty => {}
        PaneNode::Leaf(entry) => out.push(entry.clone()),
        PaneNode::Split { left, right, .. } => {
            collect_leaves(left, out);
            collect_leaves(right, out);
        }
    }
}

/// ListPanes を発行して全ペインのリーフを返す。
fn list_panes(c: &mut Conn) -> anyhow::Result<Vec<PaneEntry>> {
    let resp = c.rpc(Pdu::ListPanes(ListPanes {}))?;
    match resp {
        Pdu::ListPanesResponse(r) => {
            let mut leaves = Vec::new();
            for tab in &r.tabs {
                collect_leaves(tab, &mut leaves);
            }
            Ok(leaves)
        }
        other => anyhow::bail!("ListPanesへの予期しない応答: {}", other.pdu_name()),
    }
}

// ---------------------------------------------------------------------------
// list モード（v0回帰）
// ---------------------------------------------------------------------------
fn mode_list(c: &mut Conn) -> anyhow::Result<()> {
    println!("### バージョンハンドシェイク (手元のCODEC_VERSION={})", CODEC_VERSION);
    let resp = c.rpc(Pdu::GetCodecVersion(GetCodecVersion {}))?;
    match resp {
        Pdu::GetCodecVersionResponse(v) => {
            println!(
                "    サーバー: codec={} version={} executable={}",
                v.codec_vers,
                v.version_string,
                v.executable_path.display()
            );
            anyhow::ensure!(
                v.codec_vers == CODEC_VERSION,
                "codecバージョン不一致: local={} remote={}",
                CODEC_VERSION,
                v.codec_vers
            );
        }
        other => anyhow::bail!("予期しない応答: {}", other.pdu_name()),
    }

    println!("### ListPanes");
    let leaves = list_panes(c)?;
    for e in &leaves {
        println!(
            "      pane_id={} window={} tab={} active={} {}x{} title={:?}",
            e.pane_id, e.window_id, e.tab_id, e.is_active_pane, e.size.cols, e.size.rows, e.title
        );
    }

    let first = leaves.first().context("ペインが1つもない")?;
    let top = first.physical_top;
    let rows = first.size.rows as isize;
    println!(
        "### GetLines pane={} rows {}..{}",
        first.pane_id,
        top,
        top + rows
    );
    let resp = c.rpc(Pdu::GetLines(GetLines {
        pane_id: first.pane_id,
        lines: vec![top..top + rows],
    }))?;
    match resp {
        Pdu::GetLinesResponse(r) => {
            let (lines, _images) = r.lines.extract_data();
            println!("    --- pane {} の画面内容 ({}行) ---", first.pane_id, lines.len());
            for (idx, line) in &lines {
                println!("    {:>5} | {}", idx, line.as_str());
            }
        }
        other => anyhow::bail!("予期しない応答: {}", other.pdu_name()),
    }

    println!("### list OK: プロトコル層はGUIなしで動作");
    Ok(())
}

// ---------------------------------------------------------------------------
// attach モード（対話）
// ---------------------------------------------------------------------------
fn mode_attach(c: &mut Conn, want_pane: Option<PaneId>) -> anyhow::Result<()> {
    handshake(c)?;
    let leaves = list_panes(c)?;
    anyhow::ensure!(!leaves.is_empty(), "ペインが1つもない");

    // 対象ペイン: 指定があればそれ、なければ is_active_pane、それも無ければ先頭
    let target = match want_pane {
        Some(id) => leaves
            .iter()
            .find(|e| e.pane_id == id)
            .cloned()
            .with_context(|| format!("pane_id={} が見つからない", id))?,
        None => leaves
            .iter()
            .find(|e| e.is_active_pane)
            .cloned()
            .unwrap_or_else(|| leaves[0].clone()),
    };
    let pane_id = target.pane_id;
    let tab_id = target.tab_id;

    // ローカル端末を raw mode に。Drop で必ず復元される（panic時も unwind で復元）。
    let _raw = raw_tty::RawModeGuard::enable()?;

    // stdin 読みスレッド → Event::Input へ合流
    let input_tx = c.event_sender();
    std::thread::spawn(move || {
        let mut stdin = std::io::stdin();
        let mut buf = [0u8; 1024];
        loop {
            match stdin.read(&mut buf) {
                Ok(0) => {
                    let _ = input_tx.send(Event::Eof);
                    break;
                }
                Ok(n) => {
                    if input_tx.send(Event::Input(buf[..n].to_vec())).is_err() {
                        break;
                    }
                }
                Err(_) => {
                    let _ = input_tx.send(Event::Eof);
                    break;
                }
            }
        }
    });

    // SIGWINCH → Event::Resize
    let winch_tx = c.event_sender();
    let sigs = signal_hook::iterator::Signals::new([signal_hook::consts::SIGWINCH]);
    if let Ok(mut sigs) = sigs {
        std::thread::spawn(move || {
            for _ in sigs.forever() {
                if winch_tx.send(Event::Resize).is_err() {
                    break;
                }
            }
        });
    }

    let mut state = PaneState::new(pane_id);

    // 追跡開始。以後サーバーが変更をプッシュしてくる。
    c.rpc(Pdu::GetPaneRenderChanges(GetPaneRenderChanges { pane_id }))?;

    // 画面クリア
    let mut out = std::io::stdout();
    out.write_all(b"\x1b[2J\x1b[H")?;
    out.flush()?;

    loop {
        match c.next_event()? {
            Event::Pdu(d) => match d.pdu {
                Pdu::GetPaneRenderChangesResponse(resp) if resp.pane_id == pane_id => {
                    state.apply_delta(resp, c)?;
                    let s = state.render_to_string();
                    out.write_all(s.as_bytes())?;
                    out.flush()?;
                }
                Pdu::PaneRemoved(p) if p.pane_id == pane_id => {
                    break; // 対象ペインが消えた。綺麗に終了
                }
                // SetPalette / NotifyAlert / PaneFocused 等はbailせず無視
                _ => {}
            },
            Event::Input(bytes) => {
                if bytes.contains(&0x1D) {
                    // Ctrl-] で終了。それより前のバイトは素通しで送る
                    let idx = bytes.iter().position(|b| *b == 0x1D).unwrap();
                    if idx > 0 {
                        c.send(Pdu::WriteToPane(WriteToPane {
                            pane_id,
                            data: bytes[..idx].to_vec(),
                        }))?;
                    }
                    break;
                }
                c.send(Pdu::WriteToPane(WriteToPane {
                    pane_id,
                    data: bytes,
                }))?;
            }
            Event::Resize => {
                if let Ok(ws) = raw_tty::get_winsize() {
                    let size = TerminalSize {
                        rows: ws.rows as usize,
                        cols: ws.cols as usize,
                        pixel_width: ws.pixel_width as usize,
                        pixel_height: ws.pixel_height as usize,
                        dpi: 0,
                    };
                    c.send(Pdu::Resize(codec::Resize {
                        containing_tab_id: tab_id,
                        pane_id,
                        size,
                    }))?;
                }
            }
            Event::Eof => break,
        }
    }

    // raw mode 復元後にメッセージを出す（Dropで復元されるが順序のため明示）
    drop(_raw);
    println!("\r\n### attach 終了");
    Ok(())
}

// ---------------------------------------------------------------------------
// selftest モード（自動テスト）
// 自分でSpawnV2したペイン以外には絶対に触らない。
// ---------------------------------------------------------------------------
fn mode_selftest(c: &mut Conn) -> anyhow::Result<()> {
    handshake(c)?;

    // 隔離用に専用workspace "poctest" で新規ペインをスポーン
    let size = TerminalSize {
        rows: 24,
        cols: 80,
        pixel_width: 0,
        pixel_height: 0,
        dpi: 0,
    };
    let resp = c.rpc(Pdu::SpawnV2(SpawnV2 {
        domain: config::keyassignment::SpawnTabDomain::DefaultDomain,
        window_id: None,
        command: None,
        command_dir: None,
        size,
        workspace: "poctest".to_string(),
    }))?;
    let (pane_id, _tab_id) = match resp {
        Pdu::SpawnResponse(r) => (r.pane_id, r.tab_id),
        other => anyhow::bail!("SpawnV2への予期しない応答: {}", other.pdu_name()),
    };
    eprintln!("selftest: spawned pane_id={}", pane_id);

    let mut state = PaneState::new(pane_id);

    // 追跡開始 → キー入力送信
    c.rpc(Pdu::GetPaneRenderChanges(GetPaneRenderChanges { pane_id }))?;
    const MARKER: &str = "hello-poc-12345";
    c.send(Pdu::WriteToPane(WriteToPane {
        pane_id,
        data: format!("echo {}\r", MARKER).into_bytes(),
    }))?;

    // プッシュを受けて PaneState を更新（タイムアウト10秒）
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut found = false;
    while !found {
        match c.next_event_until(deadline)? {
            Some(Event::Pdu(d)) => match d.pdu {
                Pdu::GetPaneRenderChangesResponse(resp) if resp.pane_id == pane_id => {
                    state.apply_delta(resp, c)?;
                    if state.render_to_string().contains(MARKER) {
                        found = true;
                    }
                }
                _ => {}
            },
            Some(Event::Eof) => {
                anyhow::bail!("selftest: 接続がEOF");
            }
            Some(_) => {}
            None => break, // タイムアウト
        }
    }

    // 後片付け: 自分で作ったペインだけを KillPane
    let _ = c.rpc(Pdu::KillPane(codec::KillPane { pane_id }));

    if found {
        println!("SELFTEST OK");
        Ok(())
    } else {
        eprintln!("--- 診断: 現在のviewport描画 ---");
        eprintln!("{}", strip_ansi(&state.render_to_string()));
        eprintln!(
            "--- dims={:?} 取得済み行数={} ---",
            state.dims,
            state.lines.len()
        );
        anyhow::bail!("selftest: 10秒以内に '{}' を検出できなかった", MARKER);
    }
}

/// 診断出力用にANSIエスケープを雑に除去する。
fn strip_ansi(s: &str) -> String {
    let mut out = String::new();
    let mut chars = s.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\x1b' {
            // ESC [ ... 英字 までスキップ
            if chars.peek() == Some(&'[') {
                chars.next();
                while let Some(&c) = chars.peek() {
                    chars.next();
                    if c.is_ascii_alphabetic() {
                        break;
                    }
                }
            }
        } else {
            out.push(ch);
        }
    }
    out
}

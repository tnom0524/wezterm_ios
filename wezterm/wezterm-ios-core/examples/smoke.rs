//! スモークテスト: 実サーバー(環境変数 WEZTERM_MUX_ADDR で指定)に対する end-to-end 検証。
//!
//!   1. TCP接続 (connect)
//!   2. list_panes 表示
//!   3. workspace="poctest" に専用ペインを SpawnV2
//!   4. attach → send_input で `echo ios-core-smoke\r`
//!   5. delegate に届いた Snapshot に "ios-core-smoke" が現れることを検証
//!   6. KillPane で後片付け → poctest に stray が残らないことを確認
//!
//! 本物の作業セッションには一切触れない（poctest workspace のペインのみ）。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use wezterm_ios_core::{connect, ClientDelegate, Snapshot};

// 接続先は環境変数で指定: WEZTERM_MUX_ADDR=100.x.y.z:17777
fn addr() -> String {
    std::env::var("WEZTERM_MUX_ADDR").expect("set WEZTERM_MUX_ADDR, e.g. 100.x.y.z:17777")
}
const MARKER: &str = "ios-core-smoke";
const WORKSPACE: &str = "poctest";

struct Collector {
    marker: String,
    found: Arc<AtomicBool>,
    last_text: Arc<Mutex<String>>,
    disconnected: Arc<Mutex<Option<String>>>,
    last_dims: Arc<Mutex<(i64, i64)>>, // (physical_top, scrollback_top)
}

impl ClientDelegate for Collector {
    fn on_snapshot(&self, _pane_id: u64, snap: Snapshot) {
        let text = snapshot_to_text(&snap);
        if text.contains(&self.marker) {
            self.found.store(true, Ordering::SeqCst);
        }
        *self.last_text.lock().unwrap() = text;
        *self.last_dims.lock().unwrap() = (snap.physical_top, snap.scrollback_top);
    }
    fn on_disconnected(&self, reason: String) {
        *self.disconnected.lock().unwrap() = Some(reason);
    }
}

fn snapshot_to_text(snap: &Snapshot) -> String {
    let mut out = String::new();
    for row in &snap.rows {
        for span in &row.spans {
            out.push_str(&span.text);
        }
        out.push('\n');
    }
    out
}

fn main() {
    if let Err(e) = run() {
        eprintln!("SMOKE FAILED: {:#}", e);
        std::process::exit(1);
    }
}

fn run() -> anyhow::Result<()> {
    let found = Arc::new(AtomicBool::new(false));
    let last_text = Arc::new(Mutex::new(String::new()));
    let disconnected = Arc::new(Mutex::new(None));
    let last_dims = Arc::new(Mutex::new((0i64, 0i64)));

    let delegate = Box::new(Collector {
        marker: MARKER.to_string(),
        found: found.clone(),
        last_text: last_text.clone(),
        disconnected: disconnected.clone(),
        last_dims: last_dims.clone(),
    });

    let addr = addr();
    println!("### connect {}", addr);
    let client = connect(addr, delegate)?;

    println!("### list_panes");
    let panes = client.list_panes()?;
    for p in &panes {
        println!(
            "    pane_id={} tab={} win={} active={} {}x{} ws={:?} title={:?}",
            p.pane_id, p.tab_id, p.window_id, p.active, p.cols, p.rows, p.workspace, p.title
        );
    }

    println!("### spawn (workspace={})", WORKSPACE);
    let spawned = client.spawn(WORKSPACE.to_string(), 80, 24)?;
    println!("    spawned pane_id={} tab_id={}", spawned.pane_id, spawned.tab_id);

    // 万一に備え、後片付けは早期リターンでも走らせたいのでクロージャ化。
    let cleanup = |client: &wezterm_ios_core::MuxClient, pane_id: u64| {
        let _ = client.kill(pane_id);
    };

    println!("### attach pane_id={}", spawned.pane_id);
    if let Err(e) = client.attach(spawned.pane_id, 80, 24) {
        cleanup(&client, spawned.pane_id);
        return Err(e.into());
    }

    println!("### send_input: echo {}", MARKER);
    if let Err(e) = client.send_input(spawned.pane_id, format!("echo {}\r", MARKER).into_bytes()) {
        cleanup(&client, spawned.pane_id);
        return Err(e.into());
    }

    // Snapshot に MARKER が現れるまで最大10秒待つ。
    let deadline = Instant::now() + Duration::from_secs(10);
    while !found.load(Ordering::SeqCst) && Instant::now() < deadline {
        if let Some(reason) = disconnected.lock().unwrap().clone() {
            cleanup(&client, spawned.pane_id);
            anyhow::bail!("待機中に切断: {}", reason);
        }
        std::thread::sleep(Duration::from_millis(100));
    }

    let detected = found.load(Ordering::SeqCst);

    // --- fetch_lines 検証: viewport 先頭から24行を GetLines で取得し MARKER を確認 ---
    let mut fetch_ok = false;
    if detected {
        let (physical_top, scrollback_top) = *last_dims.lock().unwrap();
        println!(
            "### fetch_lines pane_id={} first_row={} count=24 (scrollback_top={})",
            spawned.pane_id, physical_top, scrollback_top
        );
        match client.fetch_lines(spawned.pane_id, physical_top, 24) {
            Ok(rows) => {
                let text: String = rows
                    .iter()
                    .map(|r| {
                        r.spans
                            .iter()
                            .map(|s| s.text.as_str())
                            .collect::<String>()
                            + "\n"
                    })
                    .collect();
                fetch_ok = text.contains(MARKER);
                println!(
                    "    fetched {} rows, marker {}",
                    rows.len(),
                    if fetch_ok { "FOUND" } else { "NOT FOUND" }
                );
                if !fetch_ok {
                    eprintln!("--- fetch_lines テキスト ---\n{}", text);
                }
            }
            Err(e) => eprintln!("    fetch_lines エラー: {}", e),
        }
    }

    // --- 後片付け: 自分のペインを kill ---
    println!("### kill pane_id={}", spawned.pane_id);
    cleanup(&client, spawned.pane_id);

    // poctest workspace に stray が残っていないか確認（残っていれば掃除して再確認）。
    std::thread::sleep(Duration::from_millis(300));
    let mut remaining: Vec<u64> = client
        .list_panes()?
        .into_iter()
        .filter(|p| p.workspace == WORKSPACE)
        .map(|p| p.pane_id)
        .collect();
    if !remaining.is_empty() {
        eprintln!("警告: poctest に残存ペイン {:?} を掃除します", remaining);
        for id in &remaining {
            let _ = client.kill(*id);
        }
        std::thread::sleep(Duration::from_millis(300));
        remaining = client
            .list_panes()?
            .into_iter()
            .filter(|p| p.workspace == WORKSPACE)
            .map(|p| p.pane_id)
            .collect();
    }

    client.disconnect();

    if !detected {
        eprintln!("--- 診断: 最終 viewport テキスト ---\n{}", last_text.lock().unwrap());
        anyhow::bail!("10秒以内に '{}' を Snapshot から検出できませんでした", MARKER);
    }
    anyhow::ensure!(
        remaining.is_empty(),
        "poctest に stray ペインが残りました: {:?}",
        remaining
    );
    anyhow::ensure!(
        fetch_ok,
        "fetch_lines の結果に '{}' が含まれませんでした",
        MARKER
    );

    println!("SMOKE OK");
    Ok(())
}

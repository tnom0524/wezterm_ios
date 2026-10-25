//! ペイン寸法の保存／復元を実サーバーに対して確認する手動テスト用ドライバ。
//!
//!   WEZTERM_MUX_ADDR=127.0.0.1:17799 cargo run -p wezterm-ios-core --example restore_check -- <pane_id> [cols rows]
//!
//! 標準入力から 1 行ずつ命令を読む（外側のスクリプトが `wezterm cli list` で検証する前提）:
//!   attach   … <pane_id> に attach し、自分の寸法 (既定 44x39) で Resize する
//!   restore  … 同タブの寸法を保存値へ戻す (restore_sizes)
//!   list     … list_panes の rows/cols を表示する
//!   quit     … disconnect して終了 (未復元があれば disconnect 内で戻る)
//! 各命令の完了後に "ok <cmd>" を出力する。

use std::io::BufRead;
use wezterm_ios_core::{connect, ClientDelegate, Snapshot};

struct Quiet;
impl ClientDelegate for Quiet {
    fn on_snapshot(&self, _pane_id: u64, _snap: Snapshot) {}
    fn on_disconnected(&self, reason: String) {
        eprintln!("disconnected: {}", reason);
    }
}

fn main() -> anyhow::Result<()> {
    let addr = std::env::var("WEZTERM_MUX_ADDR").expect("set WEZTERM_MUX_ADDR");
    let mut args = std::env::args().skip(1);
    let pane_id: u64 = args.next().expect("pane_id").parse()?;
    let cols: u32 = args.next().map(|s| s.parse()).transpose()?.unwrap_or(44);
    let rows: u32 = args.next().map(|s| s.parse()).transpose()?.unwrap_or(39);

    let client = connect(addr, Box::new(Quiet))?;
    let panes = client.list_panes()?;
    let tab_id = panes
        .iter()
        .find(|p| p.pane_id == pane_id)
        .map(|p| p.tab_id)
        .ok_or_else(|| anyhow::anyhow!("pane {} not found", pane_id))?;
    println!("ok connect pane={} tab={}", pane_id, tab_id);

    for line in std::io::stdin().lock().lines() {
        let cmd = line?;
        match cmd.trim() {
            "attach" => {
                client.attach(pane_id, cols, rows)?;
                println!("ok attach {}x{}", cols, rows);
            }
            "restore" => {
                client.restore_sizes(tab_id)?;
                println!("ok restore");
            }
            "list" => {
                for p in client.list_panes()? {
                    println!("  tab={} pane={} {}x{}", p.tab_id, p.pane_id, p.cols, p.rows);
                }
                println!("ok list");
            }
            "quit" => break,
            other => println!("?? {}", other),
        }
    }
    client.disconnect();
    std::thread::sleep(std::time::Duration::from_millis(300));
    println!("ok quit");
    Ok(())
}

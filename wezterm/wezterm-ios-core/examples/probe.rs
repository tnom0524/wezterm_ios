//! 診断用: 各ペインのscrollback状態を調べる（読み取りのみ）
use wezterm_ios_core::*;

struct NopDelegate;
impl ClientDelegate for NopDelegate {
    fn on_snapshot(&self, pane_id: u64, snap: Snapshot) {
        println!(
            "  snapshot pane={} physical_top={} scrollback_top={} (scrollback {}行) mouse_grabbed={}",
            pane_id,
            snap.physical_top,
            snap.scrollback_top,
            snap.physical_top - snap.scrollback_top,
            snap.mouse_grabbed
        );
    }
    fn on_disconnected(&self, _reason: String) {}
}

fn main() -> Result<(), IosCoreError> {
    let client = connect(std::env::var("WEZTERM_MUX_ADDR").expect("set WEZTERM_MUX_ADDR, e.g. 100.x.y.z:17777"), Box::new(NopDelegate))?;
    let panes = client.list_panes()?;
    // アクティブペインに現寸法のままattachしてSnapshot(dims)を観察
    if let Some(active) = panes.iter().find(|p| p.active) {
        println!("attach pane {} ({}x{})", active.pane_id, active.cols, active.rows);
        client.attach(active.pane_id, active.cols, active.rows)?;
        std::thread::sleep(std::time::Duration::from_secs(3));
    }
    for p in panes {
        println!("pane {} ({}x{}) title={:?}", p.pane_id, p.cols, p.rows, p.title);
        // 先頭0行目から20行を取得してみる（scrollbackが実在すれば内容が返る）
        let rows = client.fetch_lines(p.pane_id, 0, 20)?;
        let non_empty = rows
            .iter()
            .filter(|r| r.spans.iter().any(|s| !s.text.trim().is_empty()))
            .count();
        println!("  rows[0..20] 非空行: {}/20", non_empty);
        for (i, r) in rows.iter().take(3).enumerate() {
            let text: String = r.spans.iter().map(|s| s.text.as_str()).collect();
            println!("  [{}] {:?}", i, text.chars().take(60).collect::<String>());
        }
    }
    client.disconnect();
    Ok(())
}

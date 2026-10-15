//! 診断用: 指定ペインに attach して Snapshot の行内容を観察する（対象ペインにのみ書き込み）
//! 使い方: WEZTERM_MUX_ADDR=100.x.y.z:17777 cargo run --example probe_pane -- <pane_id>
use wezterm_ios_core::*;

struct DumpDelegate;
impl ClientDelegate for DumpDelegate {
    fn on_snapshot(&self, pane_id: u64, snap: Snapshot) {
        let non_empty: Vec<(usize, String)> = snap
            .rows
            .iter()
            .enumerate()
            .filter_map(|(i, r)| {
                let text: String = r.spans.iter().map(|s| s.text.as_str()).collect();
                if text.trim().is_empty() {
                    None
                } else {
                    Some((i, text.chars().take(60).collect()))
                }
            })
            .collect();
        println!(
            "snapshot pane={} rows={} cursor=({},{}) visible={} 非空行={}",
            pane_id,
            snap.rows.len(),
            snap.cursor_row,
            snap.cursor_col,
            snap.cursor_visible,
            non_empty.len()
        );
        for (i, t) in non_empty.iter().take(5) {
            println!("  [{}] {:?}", i, t);
        }
    }
    fn on_disconnected(&self, reason: String) {
        println!("disconnected: {}", reason);
    }
}

fn main() -> Result<(), IosCoreError> {
    let pane_id: u64 = std::env::args()
        .nth(1)
        .expect("pane_id を引数で指定")
        .parse()
        .expect("pane_id は数値");
    let addr = std::env::var("WEZTERM_MUX_ADDR").expect("set WEZTERM_MUX_ADDR");
    let client = connect(addr, Box::new(DumpDelegate))?;
    println!("attach pane {} (100x40)", pane_id);
    client.attach(pane_id, 100, 40)?;
    println!("attach 完了。30秒間 Snapshot を観察...");
    // この間に外部から send-text して push が届くか確認する
    std::thread::sleep(std::time::Duration::from_secs(30));
    // 入力も検証: echo を送って反映を見る
    client.send_input(pane_id, b"echo probe_ok\r".to_vec())?;
    println!("send_input 送信。5秒観察...");
    std::thread::sleep(std::time::Duration::from_secs(5));
    client.disconnect();
    Ok(())
}

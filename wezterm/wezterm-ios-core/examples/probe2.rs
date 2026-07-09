//! 診断用: アクティブペインにSGRマウスホイールを送り、アプリ側スクロールが
//! 成立するか検証する（上5→3秒→下5で元に戻す）
use wezterm_ios_core::*;

struct NopDelegate;
impl ClientDelegate for NopDelegate {
    fn on_snapshot(&self, _pane_id: u64, _snap: Snapshot) {}
    fn on_disconnected(&self, _reason: String) {}
}

fn main() -> Result<(), IosCoreError> {
    let client = connect(std::env::var("WEZTERM_MUX_ADDR").expect("set WEZTERM_MUX_ADDR, e.g. 100.x.y.z:17777"), Box::new(NopDelegate))?;
    let panes = client.list_panes()?;
    let active = panes.iter().find(|p| p.active).expect("no active pane");
    println!("target pane {} ({}x{})", active.pane_id, active.cols, active.rows);
    client.attach(active.pane_id, active.cols, active.rows)?;
    std::thread::sleep(std::time::Duration::from_millis(500));

    let col = (active.cols / 2).max(1);
    let row = (active.rows / 2).max(1);
    let send = |button: u8, n: usize| {
        for _ in 0..n {
            let seq = format!("\x1b[<{};{};{}M", button, col, row);
            client.send_input(active.pane_id, seq.into_bytes()).unwrap();
            std::thread::sleep(std::time::Duration::from_millis(80));
        }
    };

    println!("wheel UP x5 (座標 {},{})", col, row);
    send(64, 5);
    std::thread::sleep(std::time::Duration::from_secs(3));
    println!("wheel DOWN x5 (元に戻す)");
    send(65, 5);

    client.disconnect();
    println!("done");
    Ok(())
}

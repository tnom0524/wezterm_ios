//! ローカル端末制御（attachモード専用）。
//! termios raw mode の設定/復元、ウィンドウサイズ取得、SIGWINCH配線。
//! iOS版ではここは UITextInput 由来のキーイベントと画面サイズに置き換わる。

use std::os::unix::io::RawFd;

const STDIN_FD: RawFd = libc::STDIN_FILENO;
const STDOUT_FD: RawFd = libc::STDOUT_FILENO;

/// raw mode を掛け、Drop で必ず元の termios へ戻すガード。
pub struct RawModeGuard {
    original: libc::termios,
}

impl RawModeGuard {
    /// stdin を raw mode にする。元の設定を保持しておき Drop で復元する。
    pub fn enable() -> anyhow::Result<Self> {
        unsafe {
            let mut original: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(STDIN_FD, &mut original) != 0 {
                anyhow::bail!("tcgetattr に失敗（端末上で実行していますか？）");
            }
            let mut raw = original;
            libc::cfmakeraw(&mut raw);
            if libc::tcsetattr(STDIN_FD, libc::TCSANOW, &raw) != 0 {
                anyhow::bail!("tcsetattr に失敗");
            }
            Ok(Self { original })
        }
    }

    /// 明示的に復元する（Drop でも呼ばれるが二重呼び出しは無害）。
    pub fn restore(&self) {
        unsafe {
            libc::tcsetattr(STDIN_FD, libc::TCSANOW, &self.original);
        }
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        self.restore();
    }
}

/// 端末のウィンドウサイズ（行数・桁数・ピクセル）。
#[derive(Debug, Clone, Copy)]
pub struct WinSize {
    pub rows: u16,
    pub cols: u16,
    pub pixel_width: u16,
    pub pixel_height: u16,
}

/// ioctl TIOCGWINSZ で現在のウィンドウサイズを取得する。
pub fn get_winsize() -> anyhow::Result<WinSize> {
    unsafe {
        let mut ws: libc::winsize = std::mem::zeroed();
        if libc::ioctl(STDOUT_FD, libc::TIOCGWINSZ, &mut ws) != 0 {
            anyhow::bail!("ioctl(TIOCGWINSZ) に失敗");
        }
        Ok(WinSize {
            rows: ws.ws_row,
            cols: ws.ws_col,
            pixel_width: ws.ws_xpixel,
            pixel_height: ws.ws_ypixel,
        })
    }
}

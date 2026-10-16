//! wezterm mux の iOS クライアント向け Rust コア。
//!
//! poc-attach v1 の Transport / Conn / PaneState を土台に、DESIGN-ios.md の
//! API（connect / list_panes / attach / send_input / resize / spawn / split_pane / disconnect +
//! ClientDelegate コールバック + Snapshot 型）を UniFFI(proc-macro) で公開する。
//!
//! スレッドモデル:
//!   - `Conn::connect` が読みスレッドを立て、受信 PDU を mpsc へ流す。
//!   - `Engine`（本ファイル）が唯一の所有者としてそのチャネルを回す。
//!     serial==0 の通知は PaneState を更新し Snapshot を delegate へ push、
//!     MuxClient のメソッド呼び出しは Command としてチャネルに合流させ、
//!     Engine が直列に実行する（＝書き込みは常に1スレッドから）。
//!   - RPC 応答待ちと通知処理の競合は Conn の pending キューで吸収する。

mod conn;
mod pane_state;
mod transport;

use crate::conn::{Conn, Event};
use crate::pane_state::PaneState;
use crate::transport::{TcpTransport, Transport};
use anyhow::Context as _;
use codec::{
    GetCodecVersion, GetLines, GetPaneRenderChanges, KillPane, ListPanes, Pdu, Resize, SendPaste,
    SetClientId, SpawnV2, SplitPane, WriteToPane, CODEC_VERSION,
};
use config::keyassignment::SpawnTabDomain;
use mux::client::ClientId;
use mux::pane::PaneId;
use mux::tab::{PaneEntry, PaneNode, SplitDirection as MuxSplitDirection, SplitRequest, SplitSize};
use std::collections::HashMap;
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::sync::Mutex;
use wezterm_term::color::ColorPalette;
use wezterm_term::TerminalSize;

uniffi::setup_scaffolding!();

// ---------------------------------------------------------------------------
// UniFFI 公開型
// ---------------------------------------------------------------------------

/// 1ペインのメタ情報。
#[derive(uniffi::Record, Clone, Debug)]
pub struct PaneInfo {
    pub pane_id: u64,
    pub tab_id: u64,
    pub window_id: u64,
    pub title: String,
    pub active: bool,
    pub cols: u32,
    pub rows: u32,
    pub workspace: String,
    /// ListPanes 応答におけるタブの並び順（0 始まり、ウィンドウ横断の通し番号）。
    /// GUI 側のタブ順と一致するので、UI でのタブ番号・色分けに使う。
    pub tab_index: u32,
    /// タブのタイトル（サーバー側で未設定なら空文字）。
    pub tab_title: String,
    /// ウィンドウのタイトル（未設定なら空文字）。
    pub window_title: String,
}

/// SpawnV2 / SplitPane の結果。
#[derive(uniffi::Record, Clone, Debug)]
pub struct SpawnInfo {
    pub pane_id: u64,
    pub tab_id: u64,
    pub window_id: u64,
}

/// ペイン分割の方向。wezterm 本家の SplitDirection と同じ意味。
#[derive(uniffi::Enum, Clone, Copy, Debug)]
pub enum SplitDirection {
    /// 左右に並べる（新ペインは右側）。
    Horizontal,
    /// 上下に並べる（新ペインは下側）。
    Vertical,
}

/// 画面スナップショット（フル viewport、色は Rust 側で解決済み）。
#[derive(uniffi::Record, Clone, Debug)]
pub struct Snapshot {
    pub rows: Vec<Row>,
    pub cursor_row: i32,
    pub cursor_col: i32,
    pub cols: u32,
    pub view_rows: u32,
    /// ライブビューポートの先頭行（StableRowIndex）。スクロールバック範囲の計算に使う。
    pub physical_top: i64,
    /// スクロールバック内で取得可能な最古行（StableRowIndex）。
    pub scrollback_top: i64,
    /// マウスが掴まれているか（アプリ側スクロール vs ターミナルへ転送の判定に使う）。
    pub mouse_grabbed: bool,
    /// カーソルが表示状態かどうか（false = Hidden, true = Visible）。
    pub cursor_visible: bool,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct Row {
    pub spans: Vec<Span>,
}

/// 同一スタイルの連続テキスト。fg/bg は 0xRRGGBBAA、flags は bold|underline|reverse|italic のビットOR。
#[derive(uniffi::Record, Clone, Debug)]
pub struct Span {
    pub text: String,
    pub fg: u32,
    pub bg: u32,
    pub flags: u8,
}

/// Swift 側が実装するコールバック。Rust の読み/エンジンスレッドから呼ばれる。
#[uniffi::export(callback_interface)]
pub trait ClientDelegate: Send + Sync {
    /// 画面更新（フル viewport）。
    fn on_snapshot(&self, pane_id: u64, snap: Snapshot);
    /// 接続断（reason は人間可読の理由）。ユーザーが disconnect した場合は呼ばれない。
    fn on_disconnected(&self, reason: String);
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum IosCoreError {
    #[error("{0}")]
    Message(String),
}

fn err<E: std::fmt::Display>(e: E) -> IosCoreError {
    IosCoreError::Message(format!("{:#}", e))
}

// ---------------------------------------------------------------------------
// エンジンへ渡す命令（MuxClient メソッド → Engine）
// ---------------------------------------------------------------------------

type Reply<T> = Sender<Result<T, String>>;

pub(crate) enum Command {
    ListPanes(Reply<Vec<PaneInfo>>),
    Attach {
        pane_id: u64,
        cols: u32,
        rows: u32,
        reply: Reply<()>,
    },
    SendInput {
        pane_id: u64,
        data: Vec<u8>,
        reply: Reply<()>,
    },
    /// クリップボード文字列をブラケットペーストとしてペインへ送る（fire-and-forget）。
    SendPaste {
        pane_id: u64,
        text: String,
        reply: Reply<()>,
    },
    Resize {
        pane_id: u64,
        tab_id: u64,
        cols: u32,
        rows: u32,
        reply: Reply<()>,
    },
    Spawn {
        window_id: Option<u64>,
        workspace: String,
        cols: u32,
        rows: u32,
        reply: Reply<SpawnInfo>,
    },
    Split {
        pane_id: u64,
        direction: SplitDirection,
        reply: Reply<SpawnInfo>,
    },
    Kill {
        pane_id: u64,
        reply: Reply<()>,
    },
    FetchLines {
        pane_id: u64,
        first_row: i64,
        count: u32,
        reply: Reply<Vec<Row>>,
    },
    Disconnect,
}

// ---------------------------------------------------------------------------
// MuxClient（UniFFI Object）
// ---------------------------------------------------------------------------

#[derive(uniffi::Object)]
pub struct MuxClient {
    // Sender<Event> は Send だが Sync 保証を確実にするため Mutex で包む。
    tx: Mutex<Sender<Event>>,
}

impl MuxClient {
    fn dispatch<T>(
        &self,
        make: impl FnOnce(Reply<T>) -> Command,
    ) -> Result<T, IosCoreError> {
        let (rtx, rrx) = std::sync::mpsc::channel();
        {
            let tx = self.tx.lock().unwrap();
            tx.send(Event::Command(make(rtx)))
                .map_err(|_| IosCoreError::Message("エンジンが停止しています".into()))?;
        }
        rrx.recv()
            .map_err(|_| IosCoreError::Message("エンジンが応答を返しませんでした".into()))?
            .map_err(IosCoreError::Message)
    }
}

#[uniffi::export]
impl MuxClient {
    /// 全ペインの一覧を取得する。
    pub fn list_panes(&self) -> Result<Vec<PaneInfo>, IosCoreError> {
        self.dispatch(Command::ListPanes)
    }

    /// 指定ペインを購読開始し、要求サイズへ Resize する。以後 on_snapshot が届く。
    pub fn attach(&self, pane_id: u64, cols: u32, rows: u32) -> Result<(), IosCoreError> {
        self.dispatch(|reply| Command::Attach {
            pane_id,
            cols,
            rows,
            reply,
        })
    }

    /// キー入力（生バイト）をペインへ送る（WriteToPane）。
    pub fn send_input(&self, pane_id: u64, data: Vec<u8>) -> Result<(), IosCoreError> {
        self.dispatch(|reply| Command::SendInput {
            pane_id,
            data,
            reply,
        })
    }

    /// クリップボード文字列をブラケットペーストとしてペインへ送る（SendPaste PDU）。
    /// サーバー側がブラケットペーストのエスケープを処理する。
    pub fn send_paste(&self, pane_id: u64, text: String) -> Result<(), IosCoreError> {
        self.dispatch(|reply| Command::SendPaste {
            pane_id,
            text,
            reply,
        })
    }

    /// ペインをリサイズする。
    pub fn resize(
        &self,
        pane_id: u64,
        tab_id: u64,
        cols: u32,
        rows: u32,
    ) -> Result<(), IosCoreError> {
        self.dispatch(|reply| Command::Resize {
            pane_id,
            tab_id,
            cols,
            rows,
            reply,
        })
    }

    /// 新しいタブ（＝新規ペイン）をスポーンする（SpawnV2）。
    /// window_id を指定すると既存ウィンドウにタブを追加し、None なら新規ウィンドウを作る。
    pub fn spawn(
        &self,
        window_id: Option<u64>,
        workspace: String,
        cols: u32,
        rows: u32,
    ) -> Result<SpawnInfo, IosCoreError> {
        self.dispatch(|reply| Command::Spawn {
            window_id,
            workspace,
            cols,
            rows,
            reply,
        })
    }

    /// 既存ペインを分割して新規ペインを作る（SplitPane）。
    /// 新ペインは分割元と同じドメインで、分割元の半分のサイズになる。
    pub fn split_pane(
        &self,
        pane_id: u64,
        direction: SplitDirection,
    ) -> Result<SpawnInfo, IosCoreError> {
        self.dispatch(|reply| Command::Split {
            pane_id,
            direction,
            reply,
        })
    }

    /// 指定ペインを kill する（自分でスポーンしたペインの後片付け用）。
    pub fn kill(&self, pane_id: u64) -> Result<(), IosCoreError> {
        self.dispatch(|reply| Command::Kill { pane_id, reply })
    }

    /// スクロールバック履歴行を取得する（GetLines RPC）。
    /// first_row: 取得開始 StableRowIndex、count: 最大行数。
    /// 色解決済みの Row スライスを返す（不足行は空 Row）。
    pub fn fetch_lines(
        &self,
        pane_id: u64,
        first_row: i64,
        count: u32,
    ) -> Result<Vec<Row>, IosCoreError> {
        self.dispatch(|reply| Command::FetchLines {
            pane_id,
            first_row,
            count,
            reply,
        })
    }

    /// 接続を閉じる。エンジンスレッドを停止させ、ソケットを shutdown する。
    pub fn disconnect(&self) {
        if let Ok(tx) = self.tx.lock() {
            let _ = tx.send(Event::Command(Command::Disconnect));
        }
    }
}

/// TCP 接続 + バージョンハンドシェイク + SetClientId を行い、
/// 受信ループ（Engine）を起動して MuxClient を返す。
#[uniffi::export]
pub fn connect(
    addr: String,
    delegate: Box<dyn ClientDelegate>,
) -> Result<Arc<MuxClient>, IosCoreError> {
    let transport: Box<dyn Transport> = Box::new(TcpTransport { addr });
    let mut conn = Conn::connect(transport).map_err(err)?;
    handshake(&mut conn).map_err(err)?;

    let tx = conn.event_sender();
    let engine = Engine {
        conn,
        delegate,
        panes: HashMap::new(),
        palettes: HashMap::new(),
    };
    std::thread::Builder::new()
        .name("wezterm-ios-core-engine".into())
        .spawn(move || engine.run())
        .map_err(err)?;

    Ok(Arc::new(MuxClient { tx: Mutex::new(tx) }))
}

// ---------------------------------------------------------------------------
// エンジン（受信ループ）
// ---------------------------------------------------------------------------

struct Engine {
    conn: Conn,
    delegate: Box<dyn ClientDelegate>,
    panes: HashMap<PaneId, PaneState>,
    palettes: HashMap<PaneId, ColorPalette>,
}

impl Engine {
    fn run(mut self) {
        loop {
            let ev = match self.conn.next_event() {
                Ok(ev) => ev,
                Err(e) => {
                    self.delegate.on_disconnected(format!("{:#}", e));
                    break;
                }
            };
            match ev {
                Event::Pdu(d) => {
                    if let Err(e) = self.handle_pdu(d.pdu) {
                        self.delegate.on_disconnected(format!("{:#}", e));
                        break;
                    }
                }
                Event::Command(cmd) => {
                    if self.handle_command(cmd) {
                        break; // Disconnect
                    }
                }
                Event::Eof => {
                    self.delegate.on_disconnected("接続が閉じられました".into());
                    break;
                }
            }
        }
        // self（と conn）がここで drop され、ソケットが shutdown される。
    }

    /// サーバー由来の通知 PDU を処理する。
    fn handle_pdu(&mut self, pdu: Pdu) -> anyhow::Result<()> {
        match pdu {
            Pdu::GetPaneRenderChangesResponse(resp) => {
                let pid = resp.pane_id;
                if self.panes.contains_key(&pid) {
                    let ps = self.panes.get_mut(&pid).unwrap();
                    ps.apply_delta(resp, &mut self.conn)?;
                    self.emit_snapshot(pid);
                }
            }
            Pdu::SetPalette(sp) => {
                let pid = sp.pane_id;
                self.palettes.insert(pid, sp.palette);
                if self.panes.contains_key(&pid) {
                    self.emit_snapshot(pid);
                }
            }
            Pdu::PaneRemoved(p) => {
                self.panes.remove(&p.pane_id);
                self.palettes.remove(&p.pane_id);
            }
            // その他（NotifyAlert / PaneFocused 等）は無視。
            _ => {}
        }
        Ok(())
    }

    /// MuxClient 由来の命令を処理する。Disconnect の場合 true を返す。
    fn handle_command(&mut self, cmd: Command) -> bool {
        match cmd {
            Command::ListPanes(reply) => {
                let _ = reply.send(self.do_list().map_err(|e| format!("{:#}", e)));
            }
            Command::Attach {
                pane_id,
                cols,
                rows,
                reply,
            } => {
                let _ = reply.send(
                    self.do_attach(pane_id as PaneId, cols, rows)
                        .map_err(|e| format!("{:#}", e)),
                );
            }
            Command::SendInput {
                pane_id,
                data,
                reply,
            } => {
                let res = self
                    .conn
                    .send(Pdu::WriteToPane(WriteToPane {
                        pane_id: pane_id as PaneId,
                        data,
                    }))
                    .map(|_| ())
                    .map_err(|e| format!("{:#}", e));
                let _ = reply.send(res);
            }
            Command::SendPaste {
                pane_id,
                text,
                reply,
            } => {
                // SendPaste PDU を送る。サーバー側でブラケットペーストのラップを行う。
                let res = self
                    .conn
                    .send(Pdu::SendPaste(SendPaste {
                        pane_id: pane_id as PaneId,
                        data: text,
                    }))
                    .map(|_| ())
                    .map_err(|e| format!("{:#}", e));
                let _ = reply.send(res);
            }
            Command::Resize {
                pane_id,
                tab_id,
                cols,
                rows,
                reply,
            } => {
                let res = self
                    .conn
                    .send(Pdu::Resize(Resize {
                        containing_tab_id: tab_id as usize,
                        pane_id: pane_id as PaneId,
                        size: term_size(cols, rows),
                    }))
                    .map(|_| ())
                    .map_err(|e| format!("{:#}", e));
                let _ = reply.send(res);
            }
            Command::Spawn {
                window_id,
                workspace,
                cols,
                rows,
                reply,
            } => {
                let _ = reply.send(
                    self.do_spawn(window_id, workspace, cols, rows)
                        .map_err(|e| format!("{:#}", e)),
                );
            }
            Command::Split {
                pane_id,
                direction,
                reply,
            } => {
                let _ = reply.send(
                    self.do_split(pane_id as PaneId, direction)
                        .map_err(|e| format!("{:#}", e)),
                );
            }
            Command::Kill { pane_id, reply } => {
                let res = self
                    .conn
                    .rpc(Pdu::KillPane(KillPane {
                        pane_id: pane_id as PaneId,
                    }))
                    .map(|_| ())
                    .map_err(|e| format!("{:#}", e));
                self.panes.remove(&(pane_id as PaneId));
                self.palettes.remove(&(pane_id as PaneId));
                let _ = reply.send(res);
            }
            Command::FetchLines {
                pane_id,
                first_row,
                count,
                reply,
            } => {
                let res = self
                    .do_fetch_lines(pane_id as PaneId, first_row as isize, count)
                    .map_err(|e| format!("{:#}", e));
                let _ = reply.send(res);
            }
            Command::Disconnect => return true,
        }
        false
    }

    fn do_list(&mut self) -> anyhow::Result<Vec<PaneInfo>> {
        let leaves = self.query_leaves()?;
        Ok(leaves
            .iter()
            .map(|l| {
                let e = &l.entry;
                PaneInfo {
                    pane_id: e.pane_id as u64,
                    tab_id: e.tab_id as u64,
                    window_id: e.window_id as u64,
                    title: e.title.clone(),
                    active: e.is_active_pane,
                    cols: e.size.cols as u32,
                    rows: e.size.rows as u32,
                    workspace: e.workspace.clone(),
                    tab_index: l.tab_index,
                    tab_title: l.tab_title.clone(),
                    window_title: l.window_title.clone(),
                }
            })
            .collect())
    }

    fn do_attach(&mut self, pid: PaneId, cols: u32, rows: u32) -> anyhow::Result<()> {
        // Resize には containing_tab_id が要るので ListPanes で引く。
        let leaves = self.query_leaves()?;
        let tab_id = leaves
            .iter()
            .find(|l| l.entry.pane_id == pid)
            .map(|l| l.entry.tab_id)
            .with_context(|| format!("pane_id={} が見つかりません", pid))?;

        self.conn.rpc(Pdu::Resize(Resize {
            containing_tab_id: tab_id,
            pane_id: pid,
            size: term_size(cols, rows),
        }))?;

        self.panes.entry(pid).or_insert_with(|| PaneState::new(pid));

        // 購読開始。初回応答に初期フレームが載るので取り込んで即 Snapshot を出す。
        let resp = self
            .conn
            .rpc(Pdu::GetPaneRenderChanges(GetPaneRenderChanges { pane_id: pid }))?;
        if let Pdu::GetPaneRenderChangesResponse(r) = resp {
            if r.pane_id == pid {
                let ps = self.panes.get_mut(&pid).unwrap();
                ps.apply_delta(r, &mut self.conn)?;
                self.emit_snapshot(pid);
            }
        }
        Ok(())
    }

    fn do_spawn(
        &mut self,
        window_id: Option<u64>,
        workspace: String,
        cols: u32,
        rows: u32,
    ) -> anyhow::Result<SpawnInfo> {
        let resp = self.conn.rpc(Pdu::SpawnV2(SpawnV2 {
            domain: SpawnTabDomain::DefaultDomain,
            window_id: window_id.map(|w| w as usize),
            command: None,
            command_dir: None,
            size: term_size(cols, rows),
            workspace,
        }))?;
        match resp {
            Pdu::SpawnResponse(r) => Ok(SpawnInfo {
                pane_id: r.pane_id as u64,
                tab_id: r.tab_id as u64,
                window_id: r.window_id as u64,
            }),
            other => anyhow::bail!("SpawnV2への予期しない応答: {}", other.pdu_name()),
        }
    }

    fn do_split(&mut self, pid: PaneId, direction: SplitDirection) -> anyhow::Result<SpawnInfo> {
        let resp = self.conn.rpc(Pdu::SplitPane(SplitPane {
            pane_id: pid,
            split_request: SplitRequest {
                direction: match direction {
                    SplitDirection::Horizontal => MuxSplitDirection::Horizontal,
                    SplitDirection::Vertical => MuxSplitDirection::Vertical,
                },
                // 新ペインは右/下側に置く（本家のデフォルトと同じ）
                target_is_second: true,
                top_level: false,
                size: SplitSize::Percent(50),
            },
            command: None,
            command_dir: None,
            // 分割元ペインと同じドメインで起動する
            domain: SpawnTabDomain::CurrentPaneDomain,
            move_pane_id: None,
        }))?;
        match resp {
            Pdu::SpawnResponse(r) => Ok(SpawnInfo {
                pane_id: r.pane_id as u64,
                tab_id: r.tab_id as u64,
                window_id: r.window_id as u64,
            }),
            other => anyhow::bail!("SplitPaneへの予期しない応答: {}", other.pdu_name()),
        }
    }

    fn do_fetch_lines(
        &mut self,
        pid: PaneId,
        first_row: isize,
        count: u32,
    ) -> anyhow::Result<Vec<Row>> {
        let end_row = first_row + count as isize;
        let resp = self.conn.rpc(Pdu::GetLines(GetLines {
            pane_id: pid,
            lines: vec![first_row..end_row],
        }))?;
        match resp {
            Pdu::GetLinesResponse(r) => {
                let palette = self.palettes.get(&pid).cloned().unwrap_or_default();
                let (fetched, _images) = r.lines.extract_data();
                // fetched は (StableRowIndex, Line) のリスト。
                // first_row からの相対位置でマップし、空行で埋める。
                let mut result: Vec<Row> = (0..count)
                    .map(|_| Row { spans: Vec::new() })
                    .collect();
                for (idx, line) in fetched {
                    let offset = idx - first_row;
                    if offset >= 0 && (offset as u32) < count {
                        let spans = crate::pane_state::line_to_spans_pub(&line, &palette);
                        result[offset as usize] = Row { spans };
                    }
                }
                Ok(result)
            }
            other => anyhow::bail!("GetLinesへの予期しない応答: {}", other.pdu_name()),
        }
    }

    /// ListPanes を発行し、ペインツリーをリーフ（ペイン）に展開して返す。
    /// 各リーフには所属タブの並び順・タイトル、ウィンドウタイトルを添える。
    fn query_leaves(&mut self) -> anyhow::Result<Vec<Leaf>> {
        let resp = self.conn.rpc(Pdu::ListPanes(ListPanes {}))?;
        match resp {
            Pdu::ListPanesResponse(r) => {
                let mut leaves = Vec::new();
                for (tab_index, tab) in r.tabs.iter().enumerate() {
                    let mut entries = Vec::new();
                    collect_leaves(tab, &mut entries);
                    // tab_titles は tabs と同じ順序・同じ長さ（本家クライアントと同じ前提）
                    let tab_title = r.tab_titles.get(tab_index).cloned().unwrap_or_default();
                    for entry in entries {
                        let window_title = r
                            .window_titles
                            .get(&entry.window_id)
                            .cloned()
                            .unwrap_or_default();
                        leaves.push(Leaf {
                            entry,
                            tab_index: tab_index as u32,
                            tab_title: tab_title.clone(),
                            window_title,
                        });
                    }
                }
                Ok(leaves)
            }
            other => anyhow::bail!("ListPanesへの予期しない応答: {}", other.pdu_name()),
        }
    }

    fn emit_snapshot(&mut self, pid: PaneId) {
        if let Some(ps) = self.panes.get(&pid) {
            let palette = self.palettes.get(&pid).cloned().unwrap_or_default();
            let snap = ps.to_snapshot(&palette);
            self.delegate.on_snapshot(pid as u64, snap);
        }
    }
}

/// ListPanes のリーフ（ペイン）＋所属タブ/ウィンドウのメタ情報。
struct Leaf {
    entry: PaneEntry,
    tab_index: u32,
    tab_title: String,
    window_title: String,
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

fn term_size(cols: u32, rows: u32) -> TerminalSize {
    TerminalSize {
        rows: rows as usize,
        cols: cols as usize,
        pixel_width: 0,
        pixel_height: 0,
        dpi: 0,
    }
}

/// バージョンハンドシェイク + SetClientId（本家クライアントと同手順）。
fn handshake(conn: &mut Conn) -> anyhow::Result<()> {
    let resp = conn.rpc(Pdu::GetCodecVersion(GetCodecVersion {}))?;
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
    conn.rpc(Pdu::SetClientId(SetClientId {
        client_id: ClientId::new(),
    }))?;
    Ok(())
}

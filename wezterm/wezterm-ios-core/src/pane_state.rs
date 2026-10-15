//! ペインの画面状態モデル（poc-attach v1 から流用・改変）。
//! サーバーのプッシュを取り込み、ColorPalette で色解決した Snapshot を生成する。

use crate::conn::Conn;
use crate::{Row, Snapshot, Span};
use codec::{GetLines, GetPaneRenderChangesResponse, Pdu};
use mux::pane::PaneId;
use mux::renderable::{RenderableDimensions, StableCursorPosition};
use std::collections::HashMap;
use std::ops::Range;
use termwiz::cell::{CellAttributes, Intensity, Underline};
use termwiz::surface::Line;
use wezterm_term::color::ColorPalette;

/// StableRowIndex は wezterm-term では isize の別名。
type StableRowIndex = isize;

/// Snapshot.flags のビット定義。
const FLAG_BOLD: u8 = 1;
const FLAG_UNDERLINE: u8 = 2;
const FLAG_REVERSE: u8 = 4;
const FLAG_ITALIC: u8 = 8;

pub struct PaneState {
    pub pane_id: PaneId,
    /// StableRowIndex → 行データ。scrollback含めスパースに保持。
    pub lines: HashMap<StableRowIndex, Line>,
    pub dims: RenderableDimensions,
    pub cursor: StableCursorPosition,
    pub title: String,
    pub mouse_grabbed: bool,
}

impl PaneState {
    pub fn new(pane_id: PaneId) -> Self {
        Self {
            pane_id,
            lines: HashMap::new(),
            dims: RenderableDimensions::default(),
            cursor: StableCursorPosition::default(),
            title: String::new(),
            mouse_grabbed: false,
        }
    }

    /// サーバーからのプッシュ（GetPaneRenderChangesResponse）を取り込む。
    /// bonus_lines を反映し、dims/cursor を更新、bonus でカバーされない
    /// dirty_lines を GetLines で追加取得する。
    pub fn apply_delta(
        &mut self,
        resp: GetPaneRenderChangesResponse,
        conn: &mut Conn,
    ) -> anyhow::Result<()> {
        self.dims = resp.dimensions;
        self.cursor = resp.cursor_position;
        self.title = resp.title;
        self.mouse_grabbed = resp.mouse_grabbed;

        let (bonus, _images) = resp.bonus_lines.extract_data();
        let mut covered: HashMap<StableRowIndex, ()> = HashMap::new();
        for (idx, line) in bonus {
            covered.insert(idx, ());
            self.lines.insert(idx, line);
        }

        // bonus_lines でカバーされない dirty 行だけを GetLines で取得する。
        let mut missing: Vec<Range<StableRowIndex>> = Vec::new();
        for range in &resp.dirty_lines {
            let mut row = range.start;
            while row < range.end {
                if covered.contains_key(&row) {
                    row += 1;
                    continue;
                }
                let start = row;
                while row < range.end && !covered.contains_key(&row) {
                    row += 1;
                }
                missing.push(start..row);
            }
        }

        if !missing.is_empty() {
            let resp = conn.rpc(Pdu::GetLines(GetLines {
                pane_id: self.pane_id,
                lines: missing,
            }))?;
            match resp {
                Pdu::GetLinesResponse(r) => {
                    let (lines, _images) = r.lines.extract_data();
                    for (idx, line) in lines {
                        self.lines.insert(idx, line);
                    }
                }
                other => anyhow::bail!("GetLinesへの予期しない応答: {}", other.pdu_name()),
            }
        }
        Ok(())
    }

    /// viewport（physical_top..+viewport_rows）を色解決済み Snapshot に変換する。
    /// 色は与えられた palette（SetPalette プッシュ由来 or default）で解決する。
    pub fn to_snapshot(&self, palette: &ColorPalette) -> Snapshot {
        let top = self.dims.physical_top;
        let view_rows = self.dims.viewport_rows.max(1);
        let mut rows = Vec::with_capacity(view_rows);
        for i in 0..view_rows {
            let row_idx = top + i as StableRowIndex;
            let spans = match self.lines.get(&row_idx) {
                Some(line) => line_to_spans(line, palette),
                None => Vec::new(),
            };
            rows.push(Row { spans });
        }
        Snapshot {
            rows,
            cursor_row: (self.cursor.y - top) as i32,
            cursor_col: self.cursor.x as i32,
            cols: self.dims.cols as u32,
            view_rows: view_rows as u32,
            physical_top: self.dims.physical_top as i64,
            scrollback_top: self.dims.scrollback_top as i64,
            mouse_grabbed: self.mouse_grabbed,
            cursor_visible: self.cursor.visibility == termwiz::surface::CursorVisibility::Visible,
        }
    }
}

/// 1行を、同一スタイルの連続セルごとに Span へまとめる（エンジンからも呼べるよう pub 化）。
pub fn line_to_spans_pub(line: &Line, palette: &ColorPalette) -> Vec<Span> {
    line_to_spans(line, palette)
}

/// 1行を、同一スタイルの連続セルごとに Span へまとめる。
fn line_to_spans(line: &Line, palette: &ColorPalette) -> Vec<Span> {
    let mut spans: Vec<Span> = Vec::new();
    let mut cur: Option<(u32, u32, u8, String)> = None;
    for cell in line.visible_cells() {
        let attrs = cell.attrs();
        let (fg, bg) = resolve_colors(attrs, palette);
        let flags = flags_for(attrs);
        match &mut cur {
            Some((cfg, cbg, cflags, text)) if *cfg == fg && *cbg == bg && *cflags == flags => {
                text.push_str(cell.str());
            }
            _ => {
                if let Some((fg, bg, flags, text)) = cur.take() {
                    spans.push(Span { text, fg, bg, flags });
                }
                cur = Some((fg, bg, flags, cell.str().to_string()));
            }
        }
    }
    if let Some((fg, bg, flags, text)) = cur.take() {
        spans.push(Span { text, fg, bg, flags });
    }
    spans
}

/// fg/bg を ColorPalette で解決し、0xRRGGBBAA の u32 に詰める。
fn resolve_colors(attrs: &CellAttributes, palette: &ColorPalette) -> (u32, u32) {
    let (mut fg_c, mut bg_c) = (attrs.foreground(), attrs.background());
    // reverse は色解決前に前景/背景を入れ替える（端末の慣例）。
    if attrs.reverse() {
        std::mem::swap(&mut fg_c, &mut bg_c);
    }
    let fg = srgba_to_rgba_u32(palette.resolve_fg(fg_c));
    let bg = srgba_to_rgba_u32(palette.resolve_bg(bg_c));
    (fg, bg)
}

fn srgba_to_rgba_u32(c: termwiz::color::SrgbaTuple) -> u32 {
    let (r, g, b, a) = c.to_srgb_u8();
    (r as u32) << 24 | (g as u32) << 16 | (b as u32) << 8 | (a as u32)
}

fn flags_for(attrs: &CellAttributes) -> u8 {
    let mut f = 0u8;
    if attrs.intensity() == Intensity::Bold {
        f |= FLAG_BOLD;
    }
    if attrs.underline() != Underline::None {
        f |= FLAG_UNDERLINE;
    }
    if attrs.reverse() {
        f |= FLAG_REVERSE;
    }
    if attrs.italic() {
        f |= FLAG_ITALIC;
    }
    f
}

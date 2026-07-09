//! ペインの画面状態モデル。attach と selftest で共用する。
//! iOSコアの原型: サーバーのプッシュを取り込み、viewport を文字列に描画する。

use crate::conn::Conn;
use codec::{GetLines, GetPaneRenderChangesResponse, Pdu};
use mux::pane::PaneId;
use mux::renderable::{RenderableDimensions, StableCursorPosition};
use std::collections::HashMap;
use std::fmt::Write as _;
use std::ops::Range;
use termwiz::cell::CellAttributes;
use termwiz::color::ColorAttribute;
use termwiz::surface::Line;

/// StableRowIndex は wezterm-term では isize の別名。
/// poc-attach は wezterm-term に直接依存しないため isize を使う。
type StableRowIndex = isize;

pub struct PaneState {
    pub pane_id: PaneId,
    /// StableRowIndex → 行データ。scrollback含めスパースに保持。
    pub lines: HashMap<StableRowIndex, Line>,
    pub dims: RenderableDimensions,
    pub cursor: StableCursorPosition,
    pub title: String,
}

impl PaneState {
    pub fn new(pane_id: PaneId) -> Self {
        Self {
            pane_id,
            lines: HashMap::new(),
            dims: RenderableDimensions::default(),
            cursor: StableCursorPosition::default(),
            title: String::new(),
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
                // 連続する未カバー行を1レンジにまとめる
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

    /// viewport（physical_top..physical_top+viewport_rows）を
    /// ANSIエスケープ付き文字列に描画する。毎回フル再描画。
    pub fn render_to_string(&self) -> String {
        let top = self.dims.physical_top;
        let rows = self.dims.viewport_rows.max(1);
        let mut out = String::new();
        out.push_str("\x1b[H"); // カーソルを左上へ

        for i in 0..rows {
            let row = top + i as StableRowIndex;
            out.push_str("\x1b[K"); // この行を末尾までクリア
            if let Some(line) = self.lines.get(&row) {
                render_line(line, &mut out);
            }
            out.push_str("\x1b[0m"); // 行末で属性リセット
            if i + 1 < rows {
                out.push_str("\r\n");
            }
        }

        // カーソルを viewport 相対位置へ（1始まり）
        let cy = (self.cursor.y - top).max(0) as usize + 1;
        let cx = self.cursor.x + 1;
        let _ = write!(out, "\x1b[{};{}H", cy, cx);
        out
    }
}

/// 1行分のセルをSGR付きで文字列へ書き出す。
fn render_line(line: &Line, out: &mut String) {
    let mut prev: Option<CellAttributes> = None;
    for cell in line.visible_cells() {
        let attrs = cell.attrs();
        let changed = match &prev {
            Some(p) => !attrs_equal(p, attrs),
            None => attrs_differ_from_default(attrs),
        };
        if changed {
            out.push_str(&sgr_for(attrs));
        }
        prev = Some(attrs.clone());
        out.push_str(cell.str());
    }
}

/// 最低限の属性のみ比較（fg/bg/bold/underline/reverse）。
fn attrs_equal(a: &CellAttributes, b: &CellAttributes) -> bool {
    a.foreground() == b.foreground()
        && a.background() == b.background()
        && (a.intensity() == termwiz::cell::Intensity::Bold)
            == (b.intensity() == termwiz::cell::Intensity::Bold)
        && (a.underline() != termwiz::cell::Underline::None)
            == (b.underline() != termwiz::cell::Underline::None)
        && a.reverse() == b.reverse()
}

fn attrs_differ_from_default(a: &CellAttributes) -> bool {
    a.foreground() != ColorAttribute::Default
        || a.background() != ColorAttribute::Default
        || a.intensity() == termwiz::cell::Intensity::Bold
        || a.underline() != termwiz::cell::Underline::None
        || a.reverse()
}

/// CellAttributes から最低限のSGRシーケンスを生成する。
/// 常にリセット(0)から始めて必要な属性のみ足す。
fn sgr_for(attrs: &CellAttributes) -> String {
    let mut params: Vec<String> = vec!["0".to_string()];
    if attrs.intensity() == termwiz::cell::Intensity::Bold {
        params.push("1".to_string());
    }
    if attrs.underline() != termwiz::cell::Underline::None {
        params.push("4".to_string());
    }
    if attrs.reverse() {
        params.push("7".to_string());
    }
    append_color(&mut params, attrs.foreground(), true);
    append_color(&mut params, attrs.background(), false);
    format!("\x1b[{}m", params.join(";"))
}

/// 前景/背景色をSGRパラメータへ変換。
fn append_color(params: &mut Vec<String>, color: ColorAttribute, is_fg: bool) {
    match color {
        ColorAttribute::Default => {}
        ColorAttribute::PaletteIndex(idx)
        | ColorAttribute::TrueColorWithPaletteFallback(_, idx) => {
            // TrueColor があってもローカル端末は真色対応前提なので、
            // ここではパレット番号を優先せず、TrueColor版があればそちらを使う。
            match color {
                ColorAttribute::TrueColorWithPaletteFallback(srgba, _) => {
                    let (r, g, b, _) = srgba.to_srgb_u8();
                    push_truecolor(params, is_fg, r, g, b);
                }
                _ => push_palette(params, is_fg, idx),
            }
        }
        ColorAttribute::TrueColorWithDefaultFallback(srgba) => {
            let (r, g, b, _) = srgba.to_srgb_u8();
            push_truecolor(params, is_fg, r, g, b);
        }
    }
}

fn push_palette(params: &mut Vec<String>, is_fg: bool, idx: u8) {
    if idx < 8 {
        params.push(format!("{}", if is_fg { 30 + idx } else { 40 + idx }));
    } else if idx < 16 {
        let base = if is_fg { 90 } else { 100 };
        params.push(format!("{}", base + (idx - 8)));
    } else {
        params.push(if is_fg { "38".into() } else { "48".into() });
        params.push("5".into());
        params.push(format!("{}", idx));
    }
}

fn push_truecolor(params: &mut Vec<String>, is_fg: bool, r: u8, g: u8, b: u8) {
    params.push(if is_fg { "38".into() } else { "48".into() });
    params.push("2".into());
    params.push(format!("{}", r));
    params.push(format!("{}", g));
    params.push(format!("{}", b));
}

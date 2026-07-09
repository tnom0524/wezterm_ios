//! UniFFI バインディング生成用の薄いCLIラッパー。
//! `cargo run -p wezterm-ios-core --bin uniffi-bindgen -- generate ...` で起動する。
fn main() {
    uniffi::uniffi_bindgen_main()
}

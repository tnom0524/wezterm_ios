// NOTE: The `config` module is pure-Rust (ssh_config parser) and has no
// openssl dependency, so it is always available. All the backend modules
// (which pull in libssh-rs / ssh2 -> openssl) are gated behind the
// libssh-rs / ssh2 features so that consumers that only need the ssh_config
// parser (e.g. iOS builds) do not drag in openssl.
mod config;

#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
mod auth;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
mod channelwrap;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
mod dirwrap;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
mod filewrap;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
mod host;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
mod pty;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
mod session;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
mod sessioninner;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
mod sessionwrap;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
mod sftp;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
mod sftpwrap;

// Always available: the pure-Rust ssh_config parser.
pub use config::*;

#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
pub use auth::*;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
pub use host::*;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
pub use pty::*;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
pub use session::*;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
pub use sftp::error::*;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
pub use sftp::types::*;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
pub use sftp::*;

// NOTE: Re-exported as is exposed in a public API of this crate.
// camino is used by the always-available config module, so it stays.
pub use camino::{Utf8Path, Utf8PathBuf};
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
pub use filedescriptor::FileDescriptor;
#[cfg(any(feature = "libssh-rs", feature = "ssh2"))]
pub use portable_pty::{Child, ChildKiller, MasterPty, PtySize};

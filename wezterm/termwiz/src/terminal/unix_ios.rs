//! iOS variant of the unix terminal module.
//!
//! The full `unix.rs` module depends on the `termios` crate, which does not
//! compile for iOS targets. There is no controlling tty on iOS anyway, so
//! only the small pipe-based `UnixTerminalWaker` (used by embedding code such
//! as mux's termwiztermtab) is provided here.
use std::io::{Error as IoError, ErrorKind, Write};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};

#[derive(Clone)]
pub struct UnixTerminalWaker {
    pub(crate) pipe: Arc<Mutex<UnixStream>>,
}

impl UnixTerminalWaker {
    pub fn wake(&self) -> std::result::Result<(), IoError> {
        let mut pipe = self.pipe.lock().unwrap();
        match pipe.write(b"W") {
            Err(e) => match e.kind() {
                ErrorKind::WouldBlock => Ok(()),
                _ => Err(e),
            },
            Ok(_) => Ok(()),
        }
    }
}

use std::{
    error::Error,
    path::PathBuf,
    sync::{
        Mutex,
        mpsc::{Receiver, RecvError, Sender},
    },
};

use abi_stable::std_types::{RBoxError, RResult, RString, RVec};
use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use steel::{
    rvals::Custom,
    steel_vm::ffi::{FFIModule, FFIValue, IntoFFIVal, RegisterFFIFn},
};

steel::declare_module!(build_module);

fn file_watcher_module() -> FFIModule {
    let mut module = FFIModule::new("steel/file-watcher");

    module
        .register_fn("watch-files", watch_files)
        .register_fn("receive-event!", EventReceiver::recv)
        .register_fn("event-paths", NotifyEvent::paths)
        .register_fn("event-kind", NotifyEvent::kind);

    module
}

struct EventReceiver {
    _watcher: RecommendedWatcher,
    receiver: Mutex<Receiver<Event>>,
}
struct NotifyEvent(Event);

impl Custom for EventReceiver {}
impl Custom for NotifyEvent {}

impl EventReceiver {
    fn recv(&mut self) -> RResult<FFIValue, RBoxError> {
        let res = self
            .receiver
            .lock()
            .unwrap()
            .recv()
            .map(NotifyEvent)
            .map(|x| x.into_ffi_val().unwrap())
            .map_err(|x| RBoxError::new(x));

        match res {
            Ok(ok) => RResult::ROk(ok),
            Err(err) => RResult::RErr(err),
        }
    }
}

impl NotifyEvent {
    pub fn kind(&self) -> FFIValue {
        match self.0.kind {
            // notify::EventKind::Any => todo!(),
            // notify::EventKind::Access(access_kind) => todo!(),
            // notify::EventKind::Create(create_kind) => todo!(),
            notify::EventKind::Modify(_) => FFIValue::StringV(RString::from("modified")),
            // notify::EventKind::Remove(remove_kind) => todo!(),
            // notify::EventKind::Other => todo!(),
            _ => FFIValue::BoolV(false),
        }
    }

    pub fn paths(&self) -> RVec<FFIValue> {
        self.0
            .paths
            .iter()
            .map(|x| FFIValue::StringV(RString::from(x.as_os_str().to_str().unwrap())))
            .collect()
    }
}

fn watch_files(path: String) -> FFIValue {
    let (sender, receiver) = std::sync::mpsc::channel();

    let mut watcher = notify::recommended_watcher(move |event: Result<Event, _>| {
        if let Ok(event) = event {
            if let notify::EventKind::Modify(_) = &event.kind {
                sender.send(event).unwrap();
            }
        }
    })
    .unwrap();

    let path = PathBuf::from(path.clone());

    watcher.watch(&path, RecursiveMode::Recursive).unwrap();

    EventReceiver {
        _watcher: watcher,
        receiver: Mutex::new(receiver),
    }
    .into_ffi_val()
    .unwrap()
}

pub fn build_module() -> FFIModule {
    file_watcher_module()
}

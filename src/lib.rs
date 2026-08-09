use std::{
    collections::HashSet,
    path::PathBuf,
    sync::{
        mpsc::{channel, Receiver, TryRecvError},
        Mutex,
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
        .register_fn("try-receive-event!", EventHandle::try_recv)
        .register_fn("drain-event-paths!", EventHandle::drain_paths)
        .register_fn("event-paths", NotifyEvent::paths)
        .register_fn("event-kind", NotifyEvent::kind)
        .register_fn("make-empty-watcher", spawn_empty_watcher)
        .register_fn("watch-file!", WatchHandle::watch_file)
        .register_fn("unwatch-file!", WatchHandle::unwatch_file);

    module
}

struct WatchHandle(Mutex<RecommendedWatcher>);
struct EventHandle(Mutex<Receiver<Event>>);
struct NotifyEvent(Event);

impl Custom for WatchHandle {}
impl Custom for EventHandle {}
impl Custom for NotifyEvent {}

impl WatchHandle {
    fn watch_file(&self, path: String) {
        self.0
            .lock()
            .unwrap()
            .watch(&PathBuf::from(path), RecursiveMode::NonRecursive)
            .ok();
    }

    fn unwatch_file(&self, path: String) {
        self.0.lock().unwrap().unwatch(&PathBuf::from(path)).ok();
    }
}

impl EventHandle {
    fn try_recv(&self) -> RResult<FFIValue, RBoxError> {
        match self.0.lock().unwrap().try_recv() {
            Ok(event) => RResult::ROk(NotifyEvent(event).into_ffi_val().unwrap()),
            Err(TryRecvError::Empty) => RResult::ROk(FFIValue::BoolV(false)),
            Err(err @ TryRecvError::Disconnected) => RResult::RErr(RBoxError::new(err)),
        }
    }

    fn drain_paths(&self) -> RResult<FFIValue, RBoxError> {
        let receiver = self.0.lock().unwrap();

        let mut seen = HashSet::new();
        let mut paths = RVec::new();

        loop {
            match receiver.try_recv() {
                Ok(event) => {
                    for path in event.paths {
                        if let Some(path) = path.as_os_str().to_str() {
                            if seen.insert(path.to_owned()) {
                                paths.push(FFIValue::StringV(RString::from(path)));
                            }
                        }
                    }
                }
                Err(TryRecvError::Empty) => break,
                Err(err @ TryRecvError::Disconnected) => {
                    if paths.is_empty() {
                        return RResult::RErr(RBoxError::new(err));
                    }

                    break;
                }
            }
        }

        RResult::ROk(FFIValue::Vector(paths))
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

fn make_pair(initial: Option<(PathBuf, RecursiveMode)>) -> FFIValue {
    let (event_tx, event_rx) = channel::<Event>();

    let mut watcher = notify::recommended_watcher(move |event: Result<Event, _>| {
        if let Ok(event) = event {
            if let notify::EventKind::Modify(_) = &event.kind {
                let _ = event_tx.send(event);
            }
        }
    })
    .expect("failed to construct notify watcher");

    if let Some((path, mode)) = initial {
        let _ = watcher.watch(&path, mode);
    }

    let watch_handle = WatchHandle(Mutex::new(watcher));
    let event_handle = EventHandle(Mutex::new(event_rx));

    let v: RVec<FFIValue> = [
        watch_handle
            .into_ffi_val()
            .expect("WatchHandle into_ffi_val"),
        event_handle
            .into_ffi_val()
            .expect("EventHandle into_ffi_val"),
    ]
    .into_iter()
    .collect();
    FFIValue::Vector(v)
}

fn spawn_empty_watcher() -> FFIValue {
    make_pair(None)
}

fn watch_files(path: String) -> FFIValue {
    make_pair(Some((PathBuf::from(path), RecursiveMode::Recursive)))
}

pub fn build_module() -> FFIModule {
    file_watcher_module()
}

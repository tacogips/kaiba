use std::{
    fs,
    io::{BufRead, BufReader},
    net::TcpListener,
    process::{Child, Command, Stdio},
    sync::{mpsc, Mutex},
    time::Duration,
};
use tauri::Manager;

#[derive(Default)]
pub struct LocalServer(Mutex<Option<RunningServer>>);

struct RunningServer {
    child: Child,
    endpoint: String,
}

impl Drop for RunningServer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl LocalServer {
    pub fn stop(&self) {
        if let Ok(mut running) = self.0.lock() {
            running.take();
        }
    }

    fn start(&self, app: &tauri::AppHandle) -> Result<String, String> {
        if cfg!(target_os = "ios") || cfg!(target_os = "android") {
            return Err(
                "Local storage is currently available on macOS. Choose Remote on this device."
                    .into(),
            );
        }
        let mut running = self.0.lock().map_err(|_| "Local service lock failed")?;
        if let Some(server) = running.as_mut() {
            if server
                .child
                .try_wait()
                .map_err(|e| e.to_string())?
                .is_none()
            {
                return Ok(server.endpoint.clone());
            }
        }
        running.take();
        let root = app
            .path()
            .app_local_data_dir()
            .map_err(|e| e.to_string())?
            .join("local");
        fs::create_dir_all(&root).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700))
                .map_err(|e| e.to_string())?;
        }
        let config = root.join("config.json");
        let existing = if config.exists() {
            serde_json::from_slice(&fs::read(&config).map_err(|e| e.to_string())?)
                .map_err(|e| format!("Cannot read local AI settings: {e}"))?
        } else {
            serde_json::json!({})
        };
        let configured = local_configuration(existing.clone())?;
        if configured != existing || !config.exists() {
            let temporary = root.join("config.json.pending");
            fs::write(
                &temporary,
                serde_json::to_vec_pretty(&configured).map_err(|e| e.to_string())?,
            )
            .map_err(|e| e.to_string())?;
            fs::rename(&temporary, &config).map_err(|e| e.to_string())?;
        }
        let bundled = std::env::current_exe()
            .map_err(|e| e.to_string())?
            .parent()
            .ok_or("Application directory unavailable")?
            .join("kaiba");
        let executable = if cfg!(debug_assertions) && !bundled.is_file() {
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join(format!("local-service/kaiba-{}", env!("KAIBA_TARGET")))
        } else {
            bundled
        };
        let socket = TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
        let port = socket.local_addr().map_err(|e| e.to_string())?.port();
        drop(socket);
        let log = fs::File::create(root.join("service.log")).map_err(|e| e.to_string())?;
        let child = Command::new(executable)
            .arg("--note-root")
            .arg(&root)
            .arg("--config")
            .arg(&config)
            .args([
                "serve",
                "--host",
                "127.0.0.1",
                "--port",
                &port.to_string(),
                "--allow-unauthenticated",
                "--as-admin",
            ])
            .env("PATH", local_executable_path()?)
            .env("KAIBA_SQLITE_PATH", root.join("note-store.sqlite"))
            .env_remove("KAIBA_LIBRARY")
            .env("KAIBA_EXIT_ON_STDIN_CLOSE", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(log)
            .spawn()
            .map_err(|e| format!("Cannot start the bundled local service: {e}"))?;
        let mut server = RunningServer {
            child,
            endpoint: format!("http://127.0.0.1:{port}"),
        };
        let stdout = server
            .child
            .stdout
            .take()
            .ok_or("Local service output unavailable")?;
        let expected = format!("endpoint={}", server.endpoint);
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if line == expected {
                    let _ = sender.send(());
                }
            }
        });
        receiver
            .recv_timeout(Duration::from_secs(30))
            .map_err(|_| {
                format!(
                    "Local service could not start. Your notes are preserved. See {}",
                    root.join("service.log").display()
                )
            })?;
        let endpoint = server.endpoint.clone();
        *running = Some(server);
        Ok(endpoint)
    }
}

#[tauri::command]
pub async fn start_local_server(app: tauri::AppHandle) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || app.state::<LocalServer>().start(&app))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn stop_local_server(state: tauri::State<'_, LocalServer>) {
    state.stop();
}

// The embedded loopback server belongs to the desktop user. Give this local
// mode a usable subscription default; remote server policy remains explicit.
fn local_configuration(mut value: serde_json::Value) -> Result<serde_json::Value, String> {
    let root = value
        .as_object_mut()
        .ok_or("Local configuration must be an object")?;
    let ai = root
        .entry("ai")
        .or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
        .ok_or("Local AI configuration must be an object")?;
    ai.entry("agent").or_insert_with(|| {
        serde_json::json!({
            "backend": "agent-gateway-cli", "provider": "codex", "model": "gpt-5.6-luna"
        })
    });
    let personal = ai
        .entry("userAgent")
        .or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
        .ok_or("Local personal AI configuration must be an object")?;
    personal
        .entry("allowCodexSubscription")
        .or_insert(serde_json::Value::Bool(true));
    Ok(value)
}

fn local_executable_path() -> Result<std::ffi::OsString, String> {
    let inherited = std::env::var_os("PATH").unwrap_or_default();
    let mut directories: Vec<_> = std::env::split_paths(&inherited).collect();
    for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
        let path = std::path::PathBuf::from(directory);
        if path.is_dir() && !directories.contains(&path) {
            directories.push(path);
        }
    }
    std::env::join_paths(directories).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::local_configuration;
    use serde_json::json;

    #[test]
    fn empty_local_store_has_codex_luna_defaults() {
        let configured = local_configuration(json!({})).unwrap();
        assert_eq!(configured["ai"]["agent"]["provider"], "codex");
        assert_eq!(configured["ai"]["agent"]["model"], "gpt-5.6-luna");
        assert_eq!(
            configured["ai"]["userAgent"]["allowCodexSubscription"],
            true
        );
        assert_eq!(local_configuration(configured.clone()).unwrap(), configured);
    }

    #[test]
    fn existing_provider_and_explicit_opt_out_are_preserved() {
        let original = json!({"other": 42, "ai": {
            "agent": {"backend": "agent-gateway-cli", "provider": "openai", "model": "chosen"},
            "userAgent": {"allowCodexSubscription": false}
        }});
        assert_eq!(local_configuration(original.clone()).unwrap(), original);
        assert!(local_configuration(json!({"ai": "invalid"})).is_err());
    }
}

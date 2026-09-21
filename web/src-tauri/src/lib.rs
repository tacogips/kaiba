mod local_server;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_http::init())
        .manage(local_server::LocalServer::default())
        .invoke_handler(tauri::generate_handler![
            local_server::start_local_server,
            local_server::stop_local_server
        ])
        .build(tauri::generate_context!())
        .expect("failed to build Kaiba native client")
        .run(|app, event| {
            if matches!(event, tauri::RunEvent::Exit) {
                app.state::<local_server::LocalServer>().stop();
            }
        });
}

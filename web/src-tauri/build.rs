fn main() {
    println!(
        "cargo:rustc-env=KAIBA_TARGET={}",
        std::env::var("TARGET").expect("Cargo target")
    );
    tauri_build::build()
}

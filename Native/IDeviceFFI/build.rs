// Names the source in eider_idevice_version(): Scripts/build-idevice.sh sets
// EIDER_SOURCE_COMMIT to the Eider commit (with "-dirty" for local changes to this crate).
fn main() {
    println!("cargo:rerun-if-env-changed=EIDER_SOURCE_COMMIT");
    let source = std::env::var("EIDER_SOURCE_COMMIT").unwrap_or_else(|_| "unknown".into());
    println!(
        "cargo:rustc-env=EIDER_VERSION_STRING=eider-idevice {} (eider {source}, idevice c8fff6d7fb2690eaeb591ce510754effa7b1e19b)",
        std::env::var("CARGO_PKG_VERSION").unwrap_or_default()
    );
}

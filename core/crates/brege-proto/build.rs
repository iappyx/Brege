fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=proto/brege.proto");
    // protox compiles the .proto in pure Rust, so no `protoc` install is needed.
    let fds = protox::compile(["proto/brege.proto"], ["proto"])?;
    prost_build::Config::new().compile_fds(fds)?;
    Ok(())
}

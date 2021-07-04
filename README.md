# WebAssembly for Proxies (Zig SDK)

[Proxy-Wasm](https://github.com/proxy-wasm/spec) SDK for Zig language which enables Zig programmers to write Proxy-Wasm extensions in Zig.

See [example](example) for the demonstration.

## Build

This requires the nightly Zig.

```bash
zig build
```


## Run example with Envoyproxy

This requires the `envoy` in your PATH.

```
envoy -c example/envoy.yaml
```

## Run end-to-end test with Envoyproxy

This requires the `envoy` and `curl` in your PATH.

```
zig build e2e
```

## References
- Envoyproxy: https://www.envoyproxy.io/
- Proxy-Wasm Organization: https://github.com/proxy-wasm
- Proxy-Wasm Specification: https://github.com/proxy-wasm/spec
- Proxy-Wasm SDK (C++ SDK) https://github.com/proxy-wasm/proxy-wasm-cpp-sdk
- Proxy-Wasm SDK (Rust SDK) https://github.com/proxy-wasm/proxy-wasm-rust-sdk
- Proxy-Wasm SDK (Go SDK) https://github.com/tetratelabs/proxy-wasm-go-sdk
- Proxy-Wasm SDK (AssemlyScript SDK) https://github.com/solo-io/proxy-runtime

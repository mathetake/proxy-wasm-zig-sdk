# An example plugin with Zig SDK used at the multiple extension points in Envoy


[example.zig](example.zig) is an example of Proxy-Wasm compatible program using this SDK.

The produced binary is used at the multiple extension points as you can see in [envoy.yaml](envoy.yaml). For example, this is used for a Tcp Filters and multiple Http filters at the same time with a single binary.

The behavior is controlled by the "plugin configuration" in envoy.yaml. For example, if you pass the following json to `configuration` field in the Envoy configuration,

```json
{
    "root": "",
    "http": "header-operation",
    "tcp": ""
}
```

then the program can be used at the http filter and do some header-operations. Another example is

```json
{
    "root": "singleton",
    "http": "",
    "tcp": ""
}
```

and in this case, the Wasm Vm is created on the main thread of Envoy and do some singleton opeations (e.g. inserting shared datas so other VMs in worker threads can use).

Please refer to the source code for detail.

## Endpoints

### localhost:18000

```bash

# The wrong path to "/badclusters" is modified by Wasm VM and routed to /clusters.
$ curl -s 'localhost:18000/badclusters' | grep healthy
admin::127.0.0.1:8001::health_flags::healthy

# With "response-headers" in the path, Zig original headers are inserted.
$ curl -s 'localhost:18000?response-headers' --head | grep zig
cache-control: no-cache, max-age=0, zig-original
proxy-wasm: zig-sdk

# With "force-500" in the path, the 500 status code is received.
$ curl -s 'localhost:18000/force-500' --head | grep 500
HTTP/1.1 500 Internal Server Error

# With "tick-count" in the path, the number of onTick calls in the singletone is received.
$ curl -s 'localhost:18000?tick-count' --head | grep tick
current-tick-count: 75

# With "shared-random-value" in the path, the random value set by the singletone is received.
$ curl -s 'localhost:18000/shared-random-value' --head
shared-random-value: 8397522818561749337
```

### localhost:18001

```bash
# With "echo" in the path, the entire request body is returned as response as-is.
$ curl -XPUT 'localhost:18001/echo' --data 'this is my body'
this is my body

# With "sha256-response" in the path, the sha256 of the response body from the upstream is received.
$ curl 'localhost:18001/stats?sha256-response'
response body sha256: 32d98f08ee6d0d63ad5156c471f304c45cc71be9ce43b3fdb4ee4b80e41f4307
```

### localhost:18002

This endpoint randomly authenticate when processing request/response headers by 1) dispatching Http calls to httpbin.org/uuid, and 2) Denying requests if the first byte of the received uuid is even, otherwise allow the original HTTP request flow.

```
$ curl -s 'localhost:18002' --head
HTTP/1.1 403 Forbidden
forbidden-at: request
....

$ curl -s 'localhost:18002' --head
HTTP/1.1 403 Forbidden
forbidden-at: response

$ curl -s 'localhost:18002' --head
HTTP/1.1 200 OK
```

### localhost:18003

```bash
# An original metric of total tcp data sizes is incremented.
$ curl -s 'localhost:18003' > /dev/null
$ curl -s 'localhost:18000/stats' | grep zig
zig_sdk_tcp_total_data_size: 6844

# The value is incremented after calling it again.
$ curl -s 'localhost:18003' > /dev/null
$ curl -s 'localhost:18000/stats' | grep zig
zig_sdk_tcp_total_data_size: 13688
```

## Wasm VM logs

You can see interesting logs by Wasm VMs while invoking the above endpoints. For example:

```
[2021-05-27 18:09:15.382][2582702][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: plugin configuration: root="", http="header-operation", stream=""
[2021-05-27 18:09:15.382][2582702][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-body-operation ziglang_vm: plugin configuration: root="", http="body-operation", stream=""
[2021-05-27 18:09:15.382][2582702][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log tcp-total-data-size-counter ziglang_vm: plugin configuration: root="", http="", stream="total-data-size-counter"
[2021-05-27 18:09:15.385][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: plugin configuration: root="", http="header-operation", stream=""
[2021-05-27 18:09:15.385][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-body-operation ziglang_vm: plugin configuration: root="", http="body-operation", stream=""
[2021-05-27 18:09:15.385][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log tcp-total-data-size-counter ziglang_vm: plugin configuration: root="", http="", stream="total-data-size-counter"
[2021-05-27 18:09:18.558][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log tcp-total-data-size-counter ziglang_vm: TcpTotalDataSizeCounter context created: 4
[2021-05-27 18:09:18.558][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log tcp-total-data-size-counter ziglang_vm: connection established: 4
[2021-05-27 18:09:18.562][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log tcp-total-data-size-counter ziglang_vm: upstream connection for peer at 127.0.0.1:8001
[2021-05-27 18:09:18.563][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log tcp-total-data-size-counter ziglang_vm: downstream connection for peer at 127.0.0.1:50178
[2021-05-27 18:09:18.563][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log tcp-total-data-size-counter ziglang_vm: tcp context 4 is at logging phase..
[2021-05-27 18:09:18.563][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log tcp-total-data-size-counter ziglang_vm: deleting tcp context 4..
[2021-05-27 18:09:20.375][2582553][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log singleton ziglang_vm: on tick called at 1622106560375901383
[2021-05-27 18:09:22.208][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: HttpHeaderOperation context created: 5
[2021-05-27 18:09:22.208][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: request header: --> key: :authority, value: localhost:18000
[2021-05-27 18:09:22.208][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: request header: --> key: user-agent, value: curl/7.68.0
[2021-05-27 18:09:22.208][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: request header: --> key: x-forwarded-proto, value: http
[2021-05-27 18:09:22.208][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: request header: --> key: :scheme, value: http
[2021-05-27 18:09:22.208][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: request header: --> key: x-request-id, value: 90b5b6b5-3df6-4908-864a-8e9e0b2ff68a
[2021-05-27 18:09:22.208][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: request header: --> key: :path, value: /stats
[2021-05-27 18:09:22.208][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: request header: --> key: accept, value: */*
[2021-05-27 18:09:22.208][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: request header: --> key: :method, value: GET
[2021-05-27 18:09:22.208][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: user-agent curl/7.68.0 queued.
[2021-05-27 18:09:22.208][2582553][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log singleton ziglang_vm: user-agent curl/7.68.0 is dequeued.
[2021-05-27 18:09:22.216][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: response header: <-- key: cache-control, value: no-cache, max-age=0
[2021-05-27 18:09:22.216][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: response header: <-- key: x-content-type-options, value: nosniff
[2021-05-27 18:09:22.216][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: response header: <-- key: x-envoy-upstream-service-time, value: 6
[2021-05-27 18:09:22.216][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: response header: <-- key: :status, value: 200
[2021-05-27 18:09:22.216][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: response header: <-- key: date, value: Thu, 27 May 2021 09:09:22 GMT
[2021-05-27 18:09:22.216][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: response header: <-- key: content-type, value: text/plain; charset=UTF-8
[2021-05-27 18:09:22.216][2582701][info][wasm] [source/extensions/common/wasm/context.cc:1222] wasm log http-header-operation ziglang_vm: response header: <-- key: server, value: envoy
```
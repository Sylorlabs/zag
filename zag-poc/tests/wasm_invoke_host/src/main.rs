// Minimal wasmtime host for Zag-emitted WASM modules.
// Stubs env::{print_i32,print_u64,print_i64} and invokes exported main() -> i32.
//
// Usage:
//   wasm_invoke_host <file.wasm>              # run main(), print return on stdout
//   wasm_invoke_host <file.wasm> <expected>   # verify i32 return (test harness)

use std::env;
use std::io::Write;
use std::process;
use wasmtime::*;

fn usage() -> ! {
    eprintln!("usage: wasm_invoke_host <file.wasm> [expected-i32]");
    process::exit(2);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 || args.len() > 3 {
        usage();
    }
    let path = &args[1];
    let expect: Option<i32> = if args.len() == 3 {
        Some(args[2].parse().unwrap_or_else(|_| {
            eprintln!("invalid expected i32: {}", args[2]);
            process::exit(2);
        }))
    } else {
        None
    };

    let engine = Engine::default();
    let mut store = Store::new(&engine, ());
    let mut linker = Linker::new(&engine);

    linker
        .func_wrap("env", "print_i32", |val: i32| {
            let _ = writeln!(std::io::stdout(), "{val}");
        })
        .unwrap();
    linker.func_wrap("env", "print_u64", |_val: i64| {}).unwrap();
    linker.func_wrap("env", "print_i64", |_val: i64| {}).unwrap();

    let module = Module::from_file(&engine, path).unwrap_or_else(|e| {
        eprintln!("{e}");
        process::exit(1);
    });
    let instance = linker.instantiate(&mut store, &module).unwrap_or_else(|e| {
        eprintln!("{e}");
        process::exit(1);
    });
    let main_fn = instance
        .get_typed_func::<(), i32>(&mut store, "main")
        .unwrap_or_else(|e| {
            eprintln!("{e}");
            process::exit(1);
        });
    let got = main_fn.call(&mut store, ()).unwrap_or_else(|e| {
        eprintln!("{e}");
        process::exit(1);
    });

    if let Some(want) = expect {
        if got != want {
            eprintln!("main() returned {got}, expected {want}");
            process::exit(1);
        }
    } else {
        // Bare run mode: emit only the i32 return (for shell callers).
        print!("{got}");
    }
}
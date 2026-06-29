[package]
name = "extern_lib_test"
version = "0.1.0"

[deps]
# Link the C math library for `sqrt`.
# znc will search /usr/lib/x86_64-linux-gnu/libm.a (and other system paths).
libm = { link = "m" }

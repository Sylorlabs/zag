# Zag v2 ABI and linking (draft)

ABI is versioned separately from the language edition.  `extern "C"` selects
the target C ABI and requires C-compatible scalar/layout declarations; ordinary
Zag declarations keep a Zag ABI.  `export` and `import` control symbols and
visibility.  A C declaration with raw pointers, variadics, callbacks, errno,
or unverified ownership is unsafe.  ABI lowering must validate layout,
alignment, register classification, stack alignment, sret, and callback
trampolines with executable C↔Zag tests.

The default path remains direct static ELF without external tools.  Relocatable
objects, static archives, shared libraries, dynamic loading, and symbol lookup
are optional selected modes; no mode may silently introduce a host C compiler
or linker dependency.  ABI stability is claimed only for a named ABI version
after conformance tests pass.
